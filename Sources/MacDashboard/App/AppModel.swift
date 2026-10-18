import AppKit
import Foundation
import Observation
import ServiceManagement

enum Prefs {
    static let menuCPU = "menu.cpu"
    static let menuMemory = "menu.memory"
    static let menuNetwork = "menu.network"
    static let menuTemp = "menu.temp"
    static let menuDisk = "menu.disk"
    static let menuUsage = "menu.usage"
    static let pinnedProvider = "usage.pinned"            // legacy single pin (≤ 1.1.0)
    static let pinnedProviders = "usage.pinnedProviders"  // comma-separated ProviderID list
    static let usageMode = "usage.mode"          // "used" | "remaining"
    static let usageInterval = "usage.interval"  // minutes
    static let showAccount = "usage.showAccount"
    static let showIP = "network.showIP"
    static let language = "app.language"         // AppLanguage raw value
    static func enabled(_ id: ProviderID) -> String { "usage.enabled.\(id.rawValue)" }

    static func register() {
        var defaults: [String: Any] = [
            menuCPU: true, menuMemory: true, menuNetwork: true, menuTemp: false, menuDisk: false, menuUsage: true,
            pinnedProvider: ProviderID.claude.rawValue, usageMode: "used", usageInterval: 5, showAccount: true, showIP: true,
            language: AppLanguage.system.rawValue,
        ]
        for id in ProviderID.allCases { defaults[enabled(id)] = true }
        UserDefaults.standard.register(defaults: defaults)
    }

    static var d: UserDefaults { .standard }
    static var showRemaining: Bool { d.string(forKey: usageMode) == "remaining" }
    /// Services shown in the menu bar badge, in display order. Falls back to the single pin
    /// stored by 1.1.0 and earlier.
    static func pinned(from raw: String?) -> [ProviderID] {
        let ids = Set((raw ?? "").split(separator: ",").compactMap { ProviderID(rawValue: String($0)) })
        if !ids.isEmpty { return ProviderID.allCases.filter(ids.contains) }
        return [ProviderID(rawValue: d.string(forKey: pinnedProvider) ?? "") ?? .claude]
    }

    static var pinned: [ProviderID] { pinned(from: d.string(forKey: pinnedProviders)) }

    /// Adds or removes a service from the badge; the last pinned service stays pinned.
    static func togglePinned(_ id: ProviderID) {
        var ids = Set(pinned)
        if ids.contains(id) {
            guard ids.count > 1 else { return }
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        d.set(ProviderID.allCases.filter(ids.contains).map(\.rawValue).joined(separator: ","), forKey: pinnedProviders)
    }
    static func isEnabled(_ id: ProviderID) -> Bool { d.bool(forKey: enabled(id)) }
}

@MainActor
@Observable
final class AppModel {
    static let historyLength = 60

    var snapshot = SystemSnapshot()
    var sensors = SensorReading()
    var cpuUserHistory: [Double] = []
    var cpuSystemHistory: [Double] = []
    var gpuHistory: [Double] = []
    var netDownHistory: [Double] = []
    var netUpHistory: [Double] = []
    var diskReadHistory: [Double] = []
    var diskWriteHistory: [Double] = []
    var usage: [ProviderID: UsageState] = [:]
    /// Services whose setup was opened in Terminal, with the time it was opened.
    var connecting: [ProviderID: Date] = [:]
    /// Connects whose Terminal script never started (see `ProviderConnector.didStart`).
    var connectStalled: Set<ProviderID> = []
    var externalVolumes: [ExternalVolume] = []
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var loginError: String?

    /// Faster sampling while a popover is visible.
    var popoverOpen = false {
        didSet { if popoverOpen != oldValue { scheduleTimer() } }
    }

    @ObservationIgnored var onTick: (() -> Void)?
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var sensorReader: Sensors?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var usageTimer: Timer?
    @ObservationIgnored private var usageResetTimer: Timer?
    @ObservationIgnored private var volumeTimer: Timer?
    @ObservationIgnored private var connectTimer: Timer?
    @ObservationIgnored private var lastSensorRead = Date.distantPast
    @ObservationIgnored private let providers: [ProviderID: UsageProvider] = [
        .claude: ClaudeProvider(), .codex: CodexProvider(), .gemini: GeminiProvider(),
    ]

    func start() {
        // SMC key discovery walks ~2000 keys; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = Sensors()
            DispatchQueue.main.async { [weak self] in
                self?.sensorReader = reader
                self?.lastSensorRead = .distantPast
            }
        }
        tick()
        scheduleTimer()
        refreshUsage(force: true)
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUsage(force: false) }
        }
        refreshExternalVolumes()
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExternalVolumes() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshExternalVolumes() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampler.refreshVolume()
                self?.refreshUsage(force: true)
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = popoverOpen ? 1 : 2
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    func tick() {
        guard let snap = sampler.sample() else { return }
        snapshot = snap
        push(&cpuUserHistory, snap.cpu.user)
        push(&cpuSystemHistory, snap.cpu.system)
        push(&gpuHistory, snap.gpu.device)
        push(&netDownHistory, snap.network.downRate)
        push(&netUpHistory, snap.network.upRate)
        push(&diskReadHistory, snap.disk.readRate)
        push(&diskWriteHistory, snap.disk.writeRate)

        if let sensorReader, Date().timeIntervalSince(lastSensorRead) >= (popoverOpen ? 2 : 4) {
            sensors = sensorReader.read()
            lastSensorRead = Date()
        }
        onTick?()
    }

    /// statfs on a slow or sleeping drive can block, so scan off the main thread.
    func refreshExternalVolumes() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let volumes = ExternalVolumes.scan()
            DispatchQueue.main.async {
                if self?.externalVolumes != volumes { self?.externalVolumes = volumes }
            }
        }
    }

    private func push(_ history: inout [Double], _ value: Double?) {
        // Do not connect valid measurements across a gap or invent a zero sample.
        guard let value else { history.removeAll(keepingCapacity: true); return }
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: Usage

    var enabledProviders: [ProviderID] { ProviderID.allCases.filter(Prefs.isEnabled) }

    var isRefreshingUsage: Bool { usage.values.contains { $0.loading } }

    func refreshUsage(force: Bool, resetOnly: Bool = false, only: ProviderID? = nil) {
        let interval = TimeInterval(max(Prefs.d.integer(forKey: Prefs.usageInterval), 1) * 60)
        for id in enabledProviders where only == nil || id == only {
            var state = usage[id] ?? UsageState()
            if state.loading { continue }
            let needsReset = state.needsResetRefresh()
            if resetOnly && !needsReset { continue }
            if !force && !needsReset, let last = state.lastAttempt, Date().timeIntervalSince(last) < interval { continue }
            guard let provider = providers[id] else { continue }
            state.loading = true
            state.lastAttempt = Date()
            usage[id] = state
            Task { [weak self] in
                let result: Result<ProviderUsage, Error>
                do { result = .success(try await provider.fetch()) } catch { result = .failure(error) }
                await MainActor.run {
                    guard let self else { return }
                    var s = self.usage[id] ?? UsageState()
                    s.loading = false
                    switch result {
                    case .success(let u):
                        s.usage = u
                        s.error = nil
                    case .failure(let e):
                        s.error = e
                    }
                    self.usage[id] = s
                    if s.needsResetRefresh() {
                        self.refreshUsage(force: false, resetOnly: true)
                    }
                    self.scheduleUsageReset()
                    self.onTick?()
                }
            }
        }
        scheduleUsageReset()
    }

    // MARK: Connect

    /// Opens the service's setup in Terminal, then re-checks every 5 s (up to 10 min) so the card
    /// fills in as soon as installation and sign-in finish.
    func connect(_ id: ProviderID) {
        do {
            try ProviderConnector.openSetup(for: id)
        } catch {
            usage[id, default: UsageState()].error = error
            return
        }
        connecting[id] = Date()
        connectStalled.remove(id)
        // Long enough to answer the one-time "control Terminal" prompt before suggesting the fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.connecting[id] != nil, !ProviderConnector.didStart(id) else { return }
            self.connectStalled.insert(id)
        }
        guard connectTimer == nil else { return }
        connectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollConnections() }
        }
    }

    private func pollConnections() {
        let now = Date()
        for (id, started) in connecting {
            let state = usage[id] ?? UsageState()
            // Done once a fetch that started after Connect was clicked has finished without error.
            if !state.loading, state.error == nil, state.usage != nil, (state.lastAttempt ?? .distantPast) > started {
                connecting[id] = nil
                connectStalled.remove(id)
            } else if now.timeIntervalSince(started) > 600 {
                connecting[id] = nil
                connectStalled.remove(id)
            } else {
                refreshUsage(force: true, only: id)
            }
        }
        if connecting.isEmpty {
            connectTimer?.invalidate()
            connectTimer = nil
        }
    }

    private func scheduleUsageReset() {
        usageResetTimer?.invalidate()
        let now = Date()
        let next = enabledProviders.flatMap { id -> [Date] in
            guard let data = usage[id]?.usage else { return [] }
            return data.windows.compactMap { window in
                guard let reset = window.resetsAt, reset > now, data.updatedAt < reset else { return nil }
                return reset
            }
        }.min()
        guard let next else { return }
        usageResetTimer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshUsage(force: false, resetOnly: true)
                self?.onTick?()
            }
        }
        RunLoop.main.add(usageResetTimer!, forMode: .common)
    }

    /// Re-fetches when a popover opens and the data is older than a minute.
    func refreshUsageIfStale() {
        let stale = enabledProviders.contains { id in
            guard let last = usage[id]?.lastAttempt else { return true }
            return Date().timeIntervalSince(last) > 60
        }
        if stale { refreshUsage(force: true) }
    }

    // MARK: Login item

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L.t("설정 실패: ", "Failed: ") + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
