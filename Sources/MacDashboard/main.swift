import AppKit

if CommandLine.arguments.contains("--probe-sensors") {
    let keys = Sensors.allKeys()
    print("SMC keys:", keys.count)
    for k in keys where k.hasPrefix("T") || k.hasPrefix("F") {
        if let v = Sensors.smcNumber(k), let raw = Sensors.smcRaw(k) { print(k, raw.type, String(format: "%.2f", v)) }
    }
    print("--- HID")
    for t in Sensors.hidTemperatures() { print(t.name, String(format: "%.2f", t.value)) }
    exit(0)
}

if CommandLine.arguments.contains("--dump-system") {
    let sampler = SystemSampler()
    let sensors = Sensors()
    _ = sampler.sample()
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 1)
        let s = sampler.sample()!
        let t = sensors.read()
        print("CPU user \(Format.percent(s.cpu.user)) sys \(Format.percent(s.cpu.system)) total \(Format.percent(s.cpu.total)) cores \(s.cpu.cores.count) temp \(Format.temperature(t.cpuTemp))")
        print("GPU \(Format.percent(s.gpu.device)) renderer \(Format.percent(s.gpu.renderer)) tiler \(Format.percent(s.gpu.tiler)) temp \(Format.temperature(t.gpuTemp))")
        print("MEM used \(Format.memory(s.memory.used)) / \(Format.memory(s.memory.total)) (\(Format.percent(s.memory.usedFraction))) app \(Format.memory(s.memory.app)) wired \(Format.memory(s.memory.wired)) comp \(Format.memory(s.memory.compressed)) swap \(Format.memory(s.memory.swapUsed)) pressure \(s.memory.pressure.label)")
        print("DISK used \(Format.bytes(s.disk.used, decimals: 2)) avail \(Format.bytes(s.disk.available, decimals: 2)) total \(Format.bytes(s.disk.total, decimals: 2)) r \(Format.rate(s.disk.readRate)) w \(Format.rate(s.disk.writeRate))")
        print("NET \(s.network.interface ?? "-") \(s.network.kind) vpn=\(s.network.vpnActive) \(s.network.ipv4 ?? "-") down \(Format.rate(s.network.downRate)) up \(Format.rate(s.network.upRate))")
        for v in ExternalVolumes.scan() {
            print("EXT \(v.name) [\(v.detail)] used \(Format.bytes(v.used, decimals: 2)) avail \(Format.bytes(v.available, decimals: 2)) total \(Format.bytes(v.total, decimals: 2)) (\(Format.percent(v.usedFraction)))")
        }
        print("FANS", t.fans.map { "\(Int($0.rpm))rpm" }, "boot", s.bootTime.map { Format.duration(Date().timeIntervalSince($0)) } ?? "-")
        print("--")
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump-usage") {
    let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider(), GeminiProvider()]
    let done = DispatchSemaphore(value: 0)
    Task {
        for p in providers {
            let start = Date()
            do {
                let u = try await p.fetch()
                print("[\(p.id.displayName)] plan=\(u.plan ?? "-") account=\(u.account != nil ? "yes" : "no") note=\(u.note ?? "-") (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
                for w in u.windows {
                    print("   \(w.label) [\(w.kind.short ?? "-")] used \(Format.percent(w.effectiveUsed())) · \(Format.resetText(w.resetsAt))\(w.isVisible() ? "" : " (숨김)")")
                }
            } catch {
                print("[\(p.id.displayName)] ERROR \(error.localizedDescription)")
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
