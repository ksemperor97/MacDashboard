import CSensors
import Foundation

struct FanReading: Identifiable {
    let id: Int
    let rpm: Double
    let minRPM: Double
    let maxRPM: Double

    /// 0...1 position of the current speed inside the fan's range.
    var fraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

struct SensorReading {
    var cpuTemp: Double?
    var gpuTemp: Double?
    var fans: [FanReading] = []
}

/// Reads temperatures (IOHIDEventSystem + AppleSMC) and fan speeds (AppleSMC). No root needed.
final class Sensors {
    private var smcReady = false
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var fanCount = 0

    init() {
        smcReady = smc_open() == 0
        guard smcReady else { return }
        discoverKeys()
    }

    deinit { smc_close() }

    func read() -> SensorReading {
        var reading = SensorReading()
        let hid = Sensors.hidTemperatures()

        // CPU: SMC per-core keys when present, otherwise the PMU die sensors from HID.
        reading.cpuTemp = average(cpuKeys.compactMap(smcTemperature))
            ?? average(hid.filter { $0.name.hasPrefix("PMU tdie") }.map(\.value))
        reading.gpuTemp = average(gpuKeys.compactMap(smcTemperature))
            ?? average(hid.filter { $0.name.localizedCaseInsensitiveContains("gpu") }.map(\.value))

        for i in 0..<fanCount {
            guard let rpm = Sensors.smcNumber("F\(i)Ac") else { continue }
            let minRPM = Sensors.smcNumber("F\(i)Mn") ?? 0
            let maxRPM = Sensors.smcNumber("F\(i)Mx") ?? 0
            reading.fans.append(FanReading(id: i, rpm: max(rpm, 0), minRPM: minRPM, maxRPM: maxRPM))
        }
        return reading
    }

    // MARK: - Discovery

    private func discoverKeys() {
        fanCount = Int(Sensors.smcNumber("FNum") ?? 0)
        let keys = Sensors.allKeys()
        // Apple Silicon: Tp** = CPU performance/efficiency cores, Tg** = GPU clusters.
        // GPU clusters report near-identical values; a handful of keys is enough for the average.
        cpuKeys = Array(keys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.filter(isPlausibleTemperatureKey).prefix(24))
        gpuKeys = Array(keys.filter { $0.hasPrefix("Tg") }.filter(isPlausibleTemperatureKey).prefix(12))
    }

    private func isPlausibleTemperatureKey(_ key: String) -> Bool {
        guard let v = smcTemperature(key) else { return false }
        return v > 10 && v < 125
    }

    private func smcTemperature(_ key: String) -> Double? {
        guard let v = Sensors.smcNumber(key), v > 0, v < 150 else { return nil }
        return v
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Low level

    static func allKeys() -> [String] {
        let count = smc_key_count()
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<count where smc_key_at(i, &buf) == 0 {
            keys.append(String(cString: buf))
        }
        return keys
    }

    static func smcRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        var type: UInt32 = 0
        var size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        let ok = key.withCString { smc_read($0, &type, &bytes, &size) } == 0
        guard ok else { return nil }
        let typeString = String(bytes: [24, 16, 8, 0].map { UInt8((type >> $0) & 0xff) }, encoding: .ascii) ?? "????"
        return (typeString, Array(bytes.prefix(Int(size))))
    }

    static func smcNumber(_ key: String) -> Double? {
        guard let (type, b) = smcRaw(key), !b.isEmpty else { return nil }
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 ":
            return Double(b[0])
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    static func hidTemperatures() -> [(name: String, value: Double)] {
        let max = 128
        var names = [CChar](repeating: 0, count: max * 64)
        var values = [Double](repeating: 0, count: max)
        let n = Int(hid_read_temperatures(&names, &values, Int32(max)))
        var result: [(name: String, value: Double)] = []
        names.withUnsafeBufferPointer { buf in
            for i in 0..<n where values[i] > 0 && values[i] < 150 {
                result.append((String(cString: buf.baseAddress! + i * 64), values[i]))
            }
        }
        return result
    }
}
