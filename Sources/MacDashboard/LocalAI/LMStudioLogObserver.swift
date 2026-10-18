import Foundation

/// Follows `lms log stream --stats --json` so requests from any app (chat UI, IDE, scripts) show up
/// with LM Studio's own timings. An `input` event marks a request starting and an `output` event
/// (with stats) marks it finishing. Only the numbers are kept; prompt and output text are discarded.
final class LMStudioLogObserver: @unchecked Sendable {
    enum Event {
        case started
        case finished(SpeedSample)
    }

    // Launch, stop, restart and parsing all share one queue. A stop cannot race a pending launch.
    private let queue = DispatchQueue(label: "MacDashboard.local-ai-log")
    private var process: Process?
    private var ownerPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var wanted = false
    private var streamID: UUID?
    private let onEvent: @Sendable (Event) -> Void

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    var isRunning: Bool { queue.sync { process?.isRunning == true } }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wanted = true
            self.launchIfNeeded()
        }
    }

    func stop() {
        queue.sync {
            wanted = false
            streamID = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            // Closing this pipe tells our helper to kill only its own log process group.
            // A crash or SIGKILL closes it too, without scanning or killing other users' streams.
            try? ownerPipe?.fileHandleForWriting.close()
            ownerPipe = nil
            outputPipe = nil
            process = nil
            buffer.removeAll(keepingCapacity: false)
        }
    }

    static let arguments = ["log", "stream", "--source", "model", "--stats", "--json"]

    private func launchIfNeeded() {
        guard wanted, process?.isRunning != true,
              let lms = LocalEngines.lmsPath(), let executable = Bundle.main.executableURL else { return }
        let id = UUID()
        let p = Process()
        p.executableURL = executable
        p.arguments = ["--local-ai-log-helper", lms]
        p.currentDirectoryURL = Shell.workingDirectory
        let out = Pipe(), owner = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = owner
        streamID = id
        buffer.removeAll(keepingCapacity: true)
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in
                guard let self, self.wanted, self.streamID == id else { return }
                self.consume(data)
            }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            self?.queue.async { [weak self] in
                guard let self, self.streamID == id else { return }
                self.process = nil
                self.ownerPipe = nil
                self.outputPipe = nil
                self.buffer.removeAll(keepingCapacity: true)
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.streamID == id else { return }
                    self.launchIfNeeded()
                }
            }
        }
        do {
            try p.run()
            try? owner.fileHandleForReading.close()
            process = p
            ownerPipe = owner
            outputPipe = out
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            streamID = nil
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = Self.parse(line) { onEvent(event) }
        }
    }

    static func parse(_ line: Data) -> Event? {
        guard let json = JSON.object(line), let data = json["data"] as? [String: Any] else { return nil }
        if (data["type"] as? String) == "llm.prediction.input" { return .started }
        guard (data["type"] as? String) == "llm.prediction.output",
              let stats = data["stats"] as? [String: Any] else { return nil }
        let prompt = stats["promptTokensCount"] as? Int ?? 0
        let ttft = JSON.double(stats["timeToFirstTokenSec"])
        var sample = SpeedSample(date: JSON.date(json["timestamp"]) ?? Date(), engine: .lmStudio,
                                 model: data["modelIdentifier"] as? String ?? "?", modelID: data["modelIdentifier"] as? String, source: .observed,
                                 promptTokens: prompt, completionTokens: stats["predictedTokensCount"] as? Int ?? 0)
        sample.timeToFirstToken = ttft
        sample.generationTokensPerSecond = JSON.double(stats["tokensPerSecond"])
        sample.promptTokensPerSecond = LocalEngines.promptSpeed(tokens: prompt, ttft: ttft)
        sample.totalSeconds = (ttft ?? 0) + (JSON.double(stats["totalTimeSec"]) ?? 0)
        return .finished(sample)
    }
}
