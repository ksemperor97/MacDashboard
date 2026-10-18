import Foundation
import Observation

/// State behind the Local AI popover: which engine/model is loaded, measured speeds (benchmarks
/// and observed requests, kept on disk), and a running benchmark.
@MainActor
@Observable
final class LocalAIMonitor {
    static let historyLimit = 300
    static let contextSweep = [1_000, 8_000, 32_000]

    var status: LocalEngineStatus?
    var samples: [SpeedSample] = []        // oldest first
    var benchmark: BenchmarkProgress?
    var lastError: String?
    /// LM Studio requests that have started but not finished (from the log stream).
    var activeRequests = 0
    /// llama.cpp reports busy slots directly.
    var engineBusy: Bool?
    var lastFinishedAt: Date?

    /// Faster, more detailed polling while the popover is visible.
    var popoverOpen = false {
        didSet {
            guard popoverOpen != oldValue else { return }
            scheduleTimer()
            if popoverOpen { Task { await refresh() } }
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var benchmarkTask: Task<Void, Never>?
    @ObservationIgnored private var benchmarkID: UUID?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var observer: LMStudioLogObserver?
    @ObservationIgnored private var busyTimer: Timer?
    @ObservationIgnored private var lastStartedAt: Date?

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDashboard/local-ai-history.json")
    }

    func start() {
        stopped = false
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([SpeedSample].self, from: data) {
            samples = saved
        }
        scheduleTimer()
        // Working/idle needs to be quick: re-check every 2 s (cheap — no CLI calls).
        busyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.checkBusy() } }
        }
        Task { await refresh() }
    }

    /// True while a model is generating: an LM Studio request is in flight, llama.cpp has a busy
    /// slot, or a benchmark is running.
    var isWorking: Bool { activeRequests > 0 || engineBusy == true || benchmark != nil }

    /// A loaded Ollama model does not tell us whether another app is generating.
    var canDetermineActivity: Bool {
        switch status?.kind {
        case .lmStudio: return Prefs.d.bool(forKey: Prefs.observeLocalAI) && observer?.isRunning == true
        case .llamaCpp: return engineBusy != nil
        case .ollama, nil: return false
        }
    }

    private func checkBusy() async {
        guard !stopped else { return }
        // A request whose finish event never arrived (cancelled, crashed) shouldn't keep us "working".
        if activeRequests > 0, let started = lastStartedAt, Date().timeIntervalSince(started) > 600 {
            activeRequests = 0
        }
        let kind = status?.kind
        var busy: Bool?
        if kind == .llamaCpp, let fresh = await LocalEngines.status(of: .llamaCpp, detailed: false) {
            if fresh.models.contains(where: { $0.state == "generating" }) { busy = true }
            else if !fresh.models.isEmpty && fresh.models.allSatisfy({ $0.state == "idle" }) { busy = false }
        }
        guard !stopped, status?.kind == kind else { return }
        if busy != engineBusy { engineBusy = busy }
        onChange?()   // also lets the menu bar fall back to Idle once the after-glow ends
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: popoverOpen ? 5 : 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refresh() } }
        }
    }

    @ObservationIgnored private var displayNames: [String: String] = [:]

    func refresh() async {
        guard !stopped, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let detected = await LocalEngines.detect(detailed: popoverOpen)
        guard !stopped else { return }
        if detected?.kind != status?.kind {
            activeRequests = 0
            engineBusy = nil
            lastFinishedAt = nil
        }
        var named = detected
        if var models = named?.models {
            // Only the detailed (`lms ps`) status knows display names; remember them so requests
            // recorded while the popover is closed don't show the raw identifier instead.
            for i in models.indices {
                if models[i].name != models[i].id {
                    displayNames[models[i].id] = models[i].name
                } else if let known = displayNames[models[i].id] {
                    models[i].name = known
                }
            }
            named?.models = models
        }
        if named != status { status = named }
        updateObserver()
        onChange?()
    }

    // MARK: Observed requests

    private func updateObserver() {
        let want = status?.kind == .lmStudio && Prefs.d.bool(forKey: Prefs.observeLocalAI)
        if want {
            if observer == nil {
                observer = LMStudioLogObserver { [weak self] event in
                    Task { @MainActor in
                        guard let self, !self.stopped, self.status?.kind == .lmStudio,
                              Prefs.d.bool(forKey: Prefs.observeLocalAI) else { return }
                        switch event {
                        case .started: self.requestStarted()
                        case .finished(let sample): self.record(observed: sample)
                        }
                    }
                }
            }
            observer?.start()
        } else {
            observer?.stop()
            activeRequests = 0
            lastStartedAt = nil
        }
    }

    private func requestStarted() {
        activeRequests += 1
        lastStartedAt = Date()
        onChange?()
    }

    private func record(observed sample: SpeedSample) {
        activeRequests = max(activeRequests - 1, 0)
        lastFinishedAt = Date()
        // MacDashboard's own benchmark requests also appear in the log; keep only the benchmark copy.
        guard benchmark == nil else { onChange?(); return }
        var s = sample
        if let model = status?.models.first(where: { $0.id == (s.modelID ?? s.model) }) {
            s.modelID = model.id
            s.model = model.name
            s.quantization = model.quantization
        }
        append(s)
        Task { await refresh() }   // the model just finished; update its status right away
    }

    private func append(_ sample: SpeedSample) {
        samples.append(sample)
        if samples.count > Self.historyLimit { samples.removeFirst(samples.count - Self.historyLimit) }
        save()
        onChange?()
    }

    private func save() {
        let url = Self.historyURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: url, options: .atomic) }
    }

    /// Called when the app quits so the log stream child doesn't outlive it.
    func stop() {
        stopped = true
        timer?.invalidate()
        busyTimer?.invalidate()
        observer?.stop()
        cancelBenchmark()
    }

    func clearHistory() {
        samples.removeAll()
        save()
        onChange?()
    }

    // MARK: Benchmark

    var activeModel: LocalModel? { status?.models.first }

    /// Quick run: one short prompt. Sweep: the same at ~1k / 8k / 32k prompt tokens (capped by the
    /// loaded context), which shows how prompt processing and generation slow down with context.
    func runBenchmark(sweep: Bool) {
        guard benchmark == nil, let kind = status?.kind, let model = activeModel else {
            lastError = LocalAIError.noModel.localizedDescription
            return
        }
        let maxTokens = 128
        var sizes = sweep ? Self.contextSweep : [0]
        if let ctx = model.contextLength { sizes = sizes.filter { $0 + maxTokens + 512 <= ctx } }
        if sizes.isEmpty { sizes = [0] }
        let runID = UUID()
        benchmarkID = runID
        lastError = nil
        benchmark = BenchmarkProgress(step: 0, total: sizes.count + 1, label: L.t("모델 준비 중…", "Warming up…"))
        onChange?()

        benchmarkTask = Task { [weak self] in
            // Each continuation checks ownership: an old cancelled task must never change a new run.
            do {
                _ = try await LocalEngines.measure(kind, model: model,
                                                  prompt: LocalEngines.prompt(approximateTokens: 0), maxTokens: 8)
                for (i, size) in sizes.enumerated() {
                    try Task.checkCancellation()
                    guard let self, self.benchmarkID == runID else { return }
                    self.benchmark = BenchmarkProgress(
                        step: i + 1, total: sizes.count + 1,
                        label: size == 0 ? L.t("짧은 프롬프트 측정 중…", "Measuring a short prompt…")
                                         : L.t("입력 \(Format.tokens(size)) 토큰 측정 중…", "Measuring \(Format.tokens(size))-token input…"))
                    self.onChange?()
                    var sample = try await LocalEngines.measure(kind, model: model,
                                                                prompt: LocalEngines.prompt(approximateTokens: size),
                                                                maxTokens: maxTokens)
                    try Task.checkCancellation()
                    guard self.benchmarkID == runID else { return }
                    sample.runID = runID
                    sample.contextTokens = size == 0 ? nil : size
                    self.append(sample)
                }
            } catch {
                guard let self, self.benchmarkID == runID else { return }
                if !Task.isCancelled { self.lastError = error.localizedDescription }
            }
            guard let self, self.benchmarkID == runID else { return }
            self.benchmarkID = nil
            self.benchmarkTask = nil
            self.benchmark = nil
            self.onChange?()
        }
    }

    func cancelBenchmark() {
        benchmarkID = nil
        benchmarkTask?.cancel()
        benchmarkTask = nil
        benchmark = nil
        onChange?()
    }

    // MARK: Derived

    var currentModelSamples: [SpeedSample] {
        guard let status, let model = activeModel else { return [] }
        return samples.filter { sample in
            guard sample.engine == status.kind, sample.quantization == model.quantization else { return false }
            if let id = sample.modelID { return id == model.id }
            // Older history has only a name. Keep it only when it matches this exact model.
            return sample.model == model.id || sample.model == model.name
        }
    }

    var latest: SpeedSample? { currentModelSamples.last }

    /// The most recent typical request for the menu bar: long-context sweep steps are skipped so a
    /// 32k-token benchmark doesn't stand in for everyday speed.
    var headline: SpeedSample? {
        currentModelSamples.last { ($0.contextTokens ?? 0) <= 1_000 } ?? currentModelSamples.last
    }

    var latestRun: [SpeedSample] {
        guard let id = currentModelSamples.last(where: { $0.source == .benchmark })?.runID else { return [] }
        return currentModelSamples.filter { $0.runID == id }
    }

    /// Best short-prompt result per model + quantization, newest first.
    var comparison: [(model: String, quantization: String?, generation: Double, prompt: Double?, date: Date)] {
        var best: [String: SpeedSample] = [:]
        for s in samples where s.source == .benchmark && (s.contextTokens ?? 0) <= 1_000 {
            let key = "\(s.engine.rawValue)|\(s.modelID ?? s.model)|\(s.quantization ?? "")"
            if (s.generationTokensPerSecond ?? 0) > (best[key]?.generationTokensPerSecond ?? -1) { best[key] = s }
        }
        return best.values.sorted { $0.date > $1.date }.prefix(6).map {
            ($0.model, $0.quantization, $0.generationTokensPerSecond ?? 0, $0.promptTokensPerSecond, $0.date)
        }
    }
}
