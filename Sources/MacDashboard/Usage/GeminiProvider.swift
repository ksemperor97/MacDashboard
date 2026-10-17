import Foundation

/// Gemini limits through the Antigravity CLI. `agy -p /quota` prints the quota report without
/// starting a model turn, so it costs no quota (takes a few seconds).
struct GeminiProvider: UsageProvider {
    let id = ProviderID.gemini

    func fetch() async throws -> ProviderUsage {
        guard let agy = Shell.find("agy") else {
            throw UsageError.notLoggedIn("Antigravity CLI(agy) 설치 필요")
        }
        let data = try await Shell.run(agy, ["-p", "/quota", "--output-format", "json"], timeout: 90)
        guard let json = JSON.object(data),
              let command = json["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]]
        else { throw UsageError.badResponse }

        var windows: [UsageWindow] = []
        for group in groups {
            var groupWindows: [UsageWindow] = []
            let groupName = shortName(group["name"] as? String ?? "")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let remaining = JSON.double(bucket["remaining_fraction"]) else { continue }
                let window = bucket["window"] as? String ?? ""
                let kind: WindowKind = window == "5h" ? .fiveHour : (window == "weekly" ? .weekly : .other)
                let windowLabel = kind == .fiveHour ? "5시간" : (kind == .weekly ? "주간" : window)
                // Only the main Gemini group drives the menu bar badge.
                let badgeKind: WindowKind = groupName == "Gemini" ? kind : .other
                groupWindows.append(UsageWindow(
                    id: bucket["id"] as? String ?? UUID().uuidString,
                    label: "\(groupName) · \(windowLabel)",
                    kind: badgeKind,
                    usedFraction: 1 - remaining,
                    resetsAt: JSON.date(bucket["reset_time"]),
                    hideWhenUnused: groupName == "Claude·GPT"
                ))
            }
            // Show the 5-hour window before the weekly one, like the other services.
            windows += groupWindows.sorted { ($0.label.hasSuffix("5시간") ? 0 : 1) < ($1.label.hasSuffix("5시간") ? 0 : 1) }
        }
        guard !windows.isEmpty else { throw UsageError.badResponse }
        return ProviderUsage(provider: id, account: nil, plan: nil, windows: windows, updatedAt: Date(), note: "Antigravity 기준")
    }

    private func shortName(_ name: String) -> String {
        switch name {
        case "Gemini Models": "Gemini"
        case "Claude and GPT models": "Claude·GPT"
        default: name
        }
    }
}
