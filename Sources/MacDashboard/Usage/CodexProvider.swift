import Foundation

/// ChatGPT/Codex limits. Uses the Codex login (~/.codex/auth.json) against the usage endpoint the
/// Codex CLI itself calls, and falls back to the rate-limit snapshot in the newest local session log.
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    private var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func fetch() async throws -> ProviderUsage {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let auth = JSON.object(data),
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else { throw UsageError.notLoggedIn("Codex에서 ChatGPT 계정으로 로그인하세요") }

        let claims = (tokens["id_token"] as? String).flatMap(JSON.jwtPayload)
        let email = claims?["email"] as? String
        let authClaims = claims?["https://api.openai.com/auth"] as? [String: Any]
        let accountID = (tokens["account_id"] as? String) ?? (authClaims?["chatgpt_account_id"] as? String)

        do {
            var headers = [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "User-Agent": "codex_cli_rs/0.50.0",
            ]
            if let accountID { headers["ChatGPT-Account-Id"] = accountID }
            let json = try await HTTP.getJSON(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
            let windows = parseRemote(json)
            guard !windows.isEmpty else { throw UsageError.badResponse }
            let plan = (json["plan_type"] as? String) ?? (authClaims?["chatgpt_plan_type"] as? String)
            return ProviderUsage(provider: id, account: email, plan: plan?.capitalized, windows: windows, updatedAt: Date())
        } catch {
            // Offline or endpoint changed: use the last snapshot Codex wrote to its session log.
            guard var local = latestSessionSnapshot() else { throw error }
            local.account = email
            return local
        }
    }

    private func parseRemote(_ json: [String: Any]) -> [UsageWindow] {
        guard let limits = json["rate_limit"] as? [String: Any] else { return [] }
        let now = Date()
        return ["primary_window", "secondary_window"].compactMap { key -> UsageWindow? in
            guard let w = limits[key] as? [String: Any], let used = JSON.double(w["used_percent"]) else { return nil }
            let minutes = Int((JSON.double(w["limit_window_seconds"]) ?? 0) / 60)
            var reset = JSON.date(w["reset_at"])
            if reset == nil, let after = JSON.double(w["reset_after_seconds"]) { reset = now.addingTimeInterval(after) }
            return UsageWindow(id: key, label: WindowKind.label(minutes: minutes), kind: .from(minutes: minutes),
                               usedFraction: used / 100, resetsAt: reset)
        }
    }

    private func latestSessionSnapshot() -> ProviderUsage? {
        guard let file = newestSessionFile(), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let event = JSON.object(Data(line.utf8)) else { continue }
            let payload = (event["payload"] as? [String: Any]) ?? event
            guard let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let w = limits[key] as? [String: Any], let used = JSON.double(w["used_percent"]) else { return nil }
                let minutes = Int(JSON.double(w["window_minutes"]) ?? 0)
                return UsageWindow(id: key, label: WindowKind.label(minutes: minutes), kind: .from(minutes: minutes),
                                   usedFraction: used / 100, resetsAt: JSON.date(w["resets_at"]))
            }
            guard !windows.isEmpty else { continue }
            let updated = JSON.date(event["timestamp"]) ?? Date()
            return ProviderUsage(provider: id, plan: (limits["plan_type"] as? String)?.capitalized, windows: windows,
                                 updatedAt: updated, note: "로컬 세션 기록 기준")
        }
        return nil
    }

    /// Sessions live in sessions/YYYY/MM/DD/rollout-*.jsonl; walk the newest date folders first.
    private func newestSessionFile() -> URL? {
        let fm = FileManager.default
        func sortedDirs(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.hasDirectoryPath }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        for year in sortedDirs(codexHome.appendingPathComponent("sessions")) {
            for month in sortedDirs(year) {
                for day in sortedDirs(month) {
                    let files = ((try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                        .filter { $0.pathExtension == "jsonl" }
                    let newest = files.max {
                        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return a < b
                    }
                    if let newest { return newest }
                }
            }
        }
        return nil
    }
}
