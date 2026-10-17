import Foundation

enum ProviderID: String, CaseIterable, Identifiable, Codable {
    case claude, codex, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    var sourceName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Antigravity"
        }
    }
}

enum WindowKind {
    case fiveHour, weekly, other

    /// Short label for the menu bar badge.
    var short: String? {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "wk"
        case .other: nil
        }
    }

    static func from(minutes: Int) -> WindowKind {
        switch minutes {
        case 300: .fiveHour
        case 10080: .weekly
        default: .other
        }
    }

    static func label(minutes: Int) -> String {
        switch from(minutes: minutes) {
        case .fiveHour: return "5시간"
        case .weekly: return "주간"
        case .other:
            if minutes % 1440 == 0 { return "\(minutes / 1440)일" }
            if minutes % 60 == 0 { return "\(minutes / 60)시간" }
            return "\(minutes)분"
        }
    }
}

struct UsageWindow: Identifiable {
    let id: String
    let label: String
    let kind: WindowKind
    let usedFraction: Double   // 0...1 as reported
    let resetsAt: Date?
    /// Rows for features the user may not use at all (e.g. Claude/GPT inside Antigravity)
    /// are only listed while they have usage.
    var hideWhenUnused = false

    /// Once the reset time has passed the reported value is stale; the window starts again at 0.
    func effectiveUsed(at now: Date = Date()) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(usedFraction, 0), 1)
    }

    func isVisible(at now: Date = Date()) -> Bool {
        !hideWhenUnused || effectiveUsed(at: now) > 0
    }
}

struct ProviderUsage {
    let provider: ProviderID
    var account: String?
    var plan: String?
    var windows: [UsageWindow]
    var updatedAt: Date
    var note: String?   // e.g. "로컬 세션 기록 기준"

    /// Windows shown in the menu bar badge (first 5-hour and first weekly window).
    var badgeWindows: [UsageWindow] {
        [windows.first { $0.kind == .fiveHour }, windows.first { $0.kind == .weekly }].compactMap { $0 }
    }
}

struct UsageState {
    var usage: ProviderUsage?
    var error: String?
    var loading = false
    var lastAttempt: Date?
}

protocol UsageProvider {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderUsage
}

enum UsageError: LocalizedError {
    case notLoggedIn(String)
    case tokenExpired(String)
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let hint): "로그인 정보 없음 · \(hint)"
        case .tokenExpired(let hint): "토큰 만료 · \(hint)"
        case .http(let code): "서버 응답 오류 (HTTP \(code))"
        case .badResponse: "응답 형식을 해석할 수 없어요"
        }
    }
}

enum JSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Decodes the payload of a JWT without verifying it (only used for display fields).
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return object(data)
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    static func getJSON(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UsageError.http(code) }
        guard let json = JSON.object(data) else { throw UsageError.badResponse }
        return json
    }
}
