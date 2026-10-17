import Foundation

enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// 14.2 GB style (decimal units, like Finder and Activity Monitor).
    static func bytes(_ value: Double, decimals: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.\(decimals)f %@", v, units[i])
    }

    /// Memory sizes use binary units like Activity Monitor (64 GB RAM = 64 × 2^30).
    static func memory(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.\(i >= 3 ? 1 : 0)f %@", v, units[i])
    }

    static func bytes(_ value: UInt64, decimals: Int = 1) -> String { bytes(Double(value), decimals: decimals) }
    static func bytes(_ value: Int64, decimals: Int = 1) -> String { bytes(Double(value), decimals: decimals) }

    /// 17.0 KB/s
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond, decimals: 1) + "/s"
    }

    /// Compact rate for the menu bar: 0K, 2.0K, 16K, 1.2M
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["K", "M", "G"]
        var v = bytesPerSecond / 1000
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if v < 10 { return String(format: "%.1f%@", v, units[i]) }
        return "\(Int(v.rounded()))\(units[i])"
    }

    /// "4시간 28분", "2일 3시간", "12분"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간" }
        return "\(max(minutes, 1))분"
    }

    static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "초기화 시각 정보 없음" }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "초기화됨" }
        if remaining < 60 { return "곧 초기화" }
        return "\(duration(remaining)) 후 초기화"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f.string(from: date)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "–" }
        return "\(Int(celsius.rounded()))°"
    }
}
