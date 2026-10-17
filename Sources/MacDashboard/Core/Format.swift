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

    /// Popover rate with at most three significant digits: 512 B/s, 17.0 KB/s, 123 KB/s, 1.2 MB/s
    static func rate(_ bytesPerSecond: Double) -> String {
        let v = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        if v < 999.5 { return "\(Int(v.rounded())) B/s" }
        let (number, unit) = scaled(v / 1000, decimalsBelow: 100, units: ["KB", "MB", "GB", "TB"])
        return "\(number) \(unit)/s"
    }

    /// Compact rate for the menu bar, never more than three digits: 0.0K, 2.0K, 16K, 999K, 1.2M
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let v = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let (number, unit) = scaled(v / 1000, decimalsBelow: 10, units: ["K", "M", "G", "T"])
        return number + unit
    }

    /// Picks the 1000-based unit after rounding, so 999.6 becomes "1.0" of the next unit rather
    /// than "1000", and 9.96 becomes "10" rather than "10.0".
    private static func scaled(_ value: Double, decimalsBelow limit: Double, units: [String]) -> (String, String) {
        func text(_ v: Double) -> String {
            let oneDecimal = (v * 10).rounded() / 10
            return oneDecimal < limit ? String(format: "%.1f", oneDecimal) : String(Int(v.rounded()))
        }
        var v = value
        var i = 0
        while i < units.count - 1, (Double(text(v)) ?? 0) >= 1000 {
            v /= 1000
            i += 1
        }
        let result = text(v)
        return ((Double(result) ?? 0) >= 1000 ? "999+" : result, units[i])
    }

    /// "4시간 28분" / "4h 28m", "2일 3시간" / "2d 3h", "12분" / "12m"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return L.t("\(days)일 \(hours)시간", "\(days)d \(hours)h") }
        if hours > 0 {
            return minutes > 0 ? L.t("\(hours)시간 \(minutes)분", "\(hours)h \(minutes)m") : L.t("\(hours)시간", "\(hours)h")
        }
        return L.t("\(max(minutes, 1))분", "\(max(minutes, 1))m")
    }

    static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L.t("초기화 시각 정보 없음", "No reset time") }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return L.t("초기화됨", "Reset") }
        if remaining < 60 { return L.t("곧 초기화", "Resets soon") }
        return L.t("\(duration(remaining)) 후 초기화", "Resets in \(duration(remaining))")
    }

    /// "1.02 TB 사용 · 3.98 TB 남음 / 5.00 TB" / "1.02 TB used · 3.98 TB free / 5.00 TB"
    static func capacity(used: Int64, available: Int64, total: Int64) -> String {
        let u = bytes(used, decimals: 2), a = bytes(available, decimals: 2), t = bytes(total, decimals: 2)
        return L.t("\(u) 사용 · \(a) 남음 / \(t)", "\(u) used · \(a) free / \(t)")
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isKorean ? "ko_KR" : "en_US")
        f.dateFormat = L.isKorean ? "a h:mm" : "h:mm a"
        return f.string(from: date)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "–" }
        return "\(Int(celsius.rounded()))°"
    }
}
