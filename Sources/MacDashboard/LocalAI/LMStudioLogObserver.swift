import Foundation

/// Follows `lms log stream --stats --json` so requests from any app (chat UI, IDE, scripts) show up
/// with LM Studio's own timings. An `input` event marks a request starting and an `output` event
/// (with stats) marks it finishing. Only the numbers are kept; prompt and output text are discarded.
final class LMStudioLogObserver: @unchecked Sendable {
    enum Event {
        case started
        case finished(SpeedSample)
    }

    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var wanted = false
    private var launching = false
    private let onEvent: @Sendable (Event) -> Void

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    func start() {
        lock.lock()
        wanted = true
        let busy = process?.isRunning == true || launching
        if !busy { launching = true }
        lock.unlock()
        guard !busy else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.killOrphans()
            self?.launch()
            self?.lock.lock()
            self?.launching = false
            self?.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        wanted = false
        let p = process
        process = nil
        lock.unlock()
        p?.terminate()
    }

    static let arguments = ["log", "stream", "--source", "model", "--stats", "--json"]

    /// A previous MacDashboard that was killed leaves its `lms log stream` behind, re-parented to
    /// launchd (ppid 1). Those orphans are ours — a user's own stream has their shell as parent —
    /// so they are stopped before a new one starts.
    static func killOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let ours = "lms " + arguments.joined(separator: " ")
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "1", fields[2].hasSuffix(ours), let pid = Int32(fields[0]) else { continue }
            kill(pid, SIGTERM)
        }
    }

    private func launch() {
        guard let lms = LocalEngines.lmsPath() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lms)
        p.arguments = Self.arguments
        p.currentDirectoryURL = Shell.workingDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] _ in
            // Restart after LM Studio restarts or the stream drops, as long as it is still wanted.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard let self else { return }
                self.lock.lock()
                let again = self.wanted && self.process?.isRunning != true
                self.lock.unlock()
                if again { self.launch() }
            }
        }
        do {
            try p.run()
            lock.lock()
            process = p
            lock.unlock()
        } catch {}
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { if let event = Self.parse(line) { onEvent(event) } }
    }

    static func parse(_ line: Data) -> Event? {
        guard let json = JSON.object(line), let data = json["data"] as? [String: Any] else { return nil }
        if (data["type"] as? String) == "llm.prediction.input" { return .started }
        guard (data["type"] as? String) == "llm.prediction.output",
              let stats = data["stats"] as? [String: Any] else { return nil }
        let prompt = stats["promptTokensCount"] as? Int ?? 0
        let ttft = JSON.double(stats["timeToFirstTokenSec"])
        var sample = SpeedSample(date: JSON.date(json["timestamp"]) ?? Date(), engine: .lmStudio,
                                 model: data["modelIdentifier"] as? String ?? "?", source: .observed,
                                 promptTokens: prompt, completionTokens: stats["predictedTokensCount"] as? Int ?? 0)
        sample.timeToFirstToken = ttft
        sample.generationTokensPerSecond = JSON.double(stats["tokensPerSecond"])
        sample.promptTokensPerSecond = LocalEngines.promptSpeed(tokens: prompt, ttft: ttft)
        sample.totalSeconds = (ttft ?? 0) + (JSON.double(stats["totalTimeSec"]) ?? 0)
        return .finished(sample)
    }
}
