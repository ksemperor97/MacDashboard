import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct CPUSample {
    var user: Double = 0      // 0...1
    var system: Double = 0    // 0...1
    var cores: [Double] = []  // 0...1 per logical core
    var total: Double { min(user + system, 1) }
}

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "정상"
        case .warning: "경고"
        case .critical: "위험"
        }
    }
}

struct MemorySample {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct DiskSample {
    var total: Int64 = 0
    var available: Int64 = 0
    var readRate: Double = 0   // bytes/s
    var writeRate: Double = 0  // bytes/s
    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkSample {
    var interface: String?      // BSD name, e.g. en0
    var kind: String = "네트워크" // 이더넷, Wi-Fi, ...
    var isWiFi = false
    var vpnActive = false       // default route goes through a tunnel (utun/ipsec/ppp)
    var ipv4: String?
    var downRate: Double = 0    // bytes/s
    var upRate: Double = 0      // bytes/s
}

struct GPUSample {
    var device: Double = 0    // 0...1
    var renderer: Double = 0
    var tiler: Double = 0
}

struct SystemSnapshot {
    var cpu = CPUSample()
    var memory = MemorySample()
    var disk = DiskSample()
    var network = NetworkSample()
    var gpu = GPUSample()
    var bootTime: Date?
}

/// Collects system metrics from Mach, sysctl, IOKit and SystemConfiguration.
/// Rates (CPU, disk I/O, network) are computed from the delta to the previous call.
final class SystemSampler {
    private var prevCPUTicks: [[UInt32]] = []
    private var prevDisk: (read: UInt64, write: UInt64, time: TimeInterval)?
    private var prevNet: (name: String, rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var cachedVolume: (total: Int64, available: Int64, time: TimeInterval)?
    private var cachedInterface: (name: String?, kind: String, isWiFi: Bool, vpn: Bool, ip: String?, time: TimeInterval)?
    private let store = SCDynamicStoreCreate(nil, "MacDashboard" as CFString, nil, nil)
    private var lastTime: TimeInterval = -1

    /// Rates over very short intervals are dominated by counter batching (huge fake spikes), so a
    /// call less than 0.5 s after the previous one returns nil.
    func sample() -> SystemSnapshot? {
        let now = ProcessInfo.processInfo.systemUptime
        if lastTime >= 0, now - lastTime < 0.5 { return nil }
        lastTime = now
        var snap = SystemSnapshot()
        snap.cpu = sampleCPU()
        snap.memory = sampleMemory()
        snap.disk = sampleDisk(now: now)
        snap.network = sampleNetwork(now: now)
        snap.gpu = sampleGPU()
        snap.bootTime = bootTime()
        return snap
    }

    // MARK: CPU

    private func sampleCPU() -> CPUSample {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUSample() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [[UInt32]] = []
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { prevCPUTicks = ticks }
        guard prevCPUTicks.count == ticks.count else { return CPUSample(cores: Array(repeating: 0, count: ticks.count)) }

        var sample = CPUSample()
        var sumUser = 0.0, sumSystem = 0.0, sumTotal = 0.0
        for (cur, prev) in zip(ticks, prevCPUTicks) {
            let d = (0..<Int(CPU_STATE_MAX)).map { Double(cur[$0] &- prev[$0]) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let system = d[Int(CPU_STATE_SYSTEM)]
            let total = user + system + d[Int(CPU_STATE_IDLE)]
            sample.cores.append(total > 0 ? (user + system) / total : 0)
            sumUser += user
            sumSystem += system
            sumTotal += total
        }
        if sumTotal > 0 {
            sample.user = sumUser / sumTotal
            sample.system = sumSystem / sumTotal
        }
        return sample
    }

    // MARK: Memory

    private func sampleMemory() -> MemorySample {
        var sample = MemorySample()
        sample.total = sysctlValue("hw.memsize", as: UInt64.self) ?? 0

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // Same breakdown as Activity Monitor: App + Wired + Compressed = Memory Used.
            sample.app = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
            sample.wired = UInt64(stats.wire_count) * page
            sample.compressed = UInt64(stats.compressor_page_count) * page
        }

        if let swap = sysctlValue("vm.swapusage", as: xsw_usage.self) {
            sample.swapUsed = swap.xsu_used
        }
        if let level = sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self) {
            sample.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        return sample
    }

    // MARK: Disk

    private func sampleDisk(now: TimeInterval) -> DiskSample {
        var sample = DiskSample()
        if cachedVolume == nil || now - cachedVolume!.time > 30 {
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                cachedVolume = (Int64(values.volumeTotalCapacity ?? 0), values.volumeAvailableCapacityForImportantUsage ?? 0, now)
            }
        }
        if let v = cachedVolume {
            sample.total = v.total
            sample.available = v.available
        }

        let (read, write) = blockStorageBytes()
        if let prev = prevDisk, now > prev.time {
            let dt = now - prev.time
            sample.readRate = Double(read &- prev.read) / dt
            sample.writeRate = Double(write &- prev.write) / dt
        }
        prevDisk = (read, write, now)
        return sample
    }

    /// Invalidates the cached volume size so the next sample re-reads it.
    func refreshVolume() { cachedVolume = nil }

    private func blockStorageBytes() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    // MARK: Network

    private func sampleNetwork(now: TimeInterval) -> NetworkSample {
        if cachedInterface == nil || now - cachedInterface!.time > 10 {
            let primary = primaryInterface()
            let vpn = primary.map(isTunnel) ?? false
            // With a VPN the default route is a tunnel; report the physical link that carries it.
            let name = vpn ? (physicalInterface() ?? primary) : primary
            let (kind, isWiFi) = name.map(interfaceKind) ?? ("네트워크", false)
            cachedInterface = (name, kind, isWiFi, vpn, name.flatMap(ipv4Address), now)
        }
        var sample = NetworkSample()
        guard let iface = cachedInterface else { return sample }
        sample.interface = iface.name
        sample.kind = iface.kind
        sample.isWiFi = iface.isWiFi
        sample.vpnActive = iface.vpn
        sample.ipv4 = iface.ip
        guard let name = iface.name, let counters = interfaceCounters()[name] else { return sample }

        if let prev = prevNet, prev.name == name, now > prev.time {
            let dt = now - prev.time
            sample.downRate = Double(counters.rx &- prev.rx) / dt
            sample.upRate = Double(counters.tx &- prev.tx) / dt
        }
        prevNet = (name, counters.rx, counters.tx, now)
        return sample
    }

    private func primaryInterface() -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
    }

    /// First non-tunnel interface with an IPv4 address, in the user's network service order.
    private func physicalInterface() -> String? {
        guard let store,
              let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
              let order = setup["ServiceOrder"] as? [String]
        else { return nil }
        for service in order {
            guard let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
                  let name = state["InterfaceName"] as? String, !isTunnel(name)
            else { continue }
            return name
        }
        return nil
    }

    private func interfaceKind(_ bsdName: String) -> (String, Bool) {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }),
              let type = SCNetworkInterfaceGetInterfaceType(match)
        else { return (bsdName.hasPrefix("utun") ? "VPN" : "네트워크", false) }
        if type == kSCNetworkInterfaceTypeIEEE80211 { return ("Wi-Fi", true) }
        if type == kSCNetworkInterfaceTypeEthernet { return ("이더넷", false) }
        return ((SCNetworkInterfaceGetLocalizedDisplayName(match) as String?) ?? bsdName, false)
    }

    private func ipv4Address(_ bsdName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == bsdName, let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// 64-bit byte counters per interface (NET_RT_IFLIST2 avoids the 4 GB wrap of getifaddrs).
    private func interfaceCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: (UInt64, UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let hdr2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(hdr2.ifm_index), &nameBuf) != nil {
                        result[String(cString: nameBuf)] = (hdr2.ifm_data.ifi_ibytes, hdr2.ifm_data.ifi_obytes)
                    }
                }
                guard hdr.ifm_msglen > 0 else { break }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return result
    }

    // MARK: GPU

    private func sampleGPU() -> GPUSample {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return GPUSample()
        }
        defer { IOObjectRelease(iterator) }
        var sample = GPUSample()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func pct(_ key: String) -> Double { ((stats[key] as? NSNumber)?.doubleValue ?? 0) / 100 }
            sample.device = max(sample.device, pct("Device Utilization %"))
            sample.renderer = max(sample.renderer, pct("Renderer Utilization %"))
            sample.tiler = max(sample.tiler, pct("Tiler Utilization %"))
        }
        return sample
    }

    // MARK: Misc

    private func bootTime() -> Date? {
        guard let tv = sysctlValue("kern.boottime", as: timeval.self) else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private func sysctlValue<T>(_ name: String, as: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard sysctlbyname(name, ptr, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return ptr.load(as: T.self)
    }
}
