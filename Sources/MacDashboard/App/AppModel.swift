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
    @ObservationIgnored private var volumeTimer: Timer?
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

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: Usage

    var enabledProviders: [ProviderID] { ProviderID.allCases.filter(Prefs.isEnabled) }

    var isRefreshingUsage: Bool { usage.values.contains { $0.loading } }

    func refreshUsage(force: Bool) {
        let interval = TimeInterval(max(Prefs.d.integer(forKey: Prefs.usageInterval), 1) * 60)
        for id in enabledProviders {
            var state = usage[id] ?? UsageState()
            if state.loading { continue }
            if !force, let last = state.lastAttempt, Date().timeIntervalSince(last) < interval { continue }
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
                    self.onTick?()
                }
            }
        }
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
