import Foundation

/// Claude subscription limits via the OAuth token that Claude Code keeps in the login keychain.
/// The token is only read; refreshing is left to Claude Code itself so its login never breaks.
struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude

    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
    }

    func fetch() async throws -> ProviderUsage {
        var creds = try await readCredentials()
        if let exp = creds.expiresAt, exp < Date().addingTimeInterval(60) {
            // `claude auth status` refreshes an expired session as a side effect; read again afterwards.
            _ = try? await authStatus()
            creds = try await readCredentials()
            if let exp = creds.expiresAt, exp < Date() {
                throw UsageError.tokenExpired(runClaudeHint)
            }
        }

        let json: [String: Any]
        do {
            json = try await requestUsage(token: creds.accessToken)
        } catch UsageError.http(401) {
            _ = try? await authStatus()
            let fresh = try await readCredentials()
            guard fresh.accessToken != creds.accessToken else {
                throw UsageError.tokenExpired(runClaudeHint)
            }
            json = try await requestUsage(token: fresh.accessToken)
        }

        let labels: [(key: String, label: Loc, kind: WindowKind)] = [
            ("five_hour", WindowKind.fiveHourLabel, .fiveHour),
            ("seven_day", Loc("주간 · 전체", "Weekly · All models"), .weekly),
            ("seven_day_sonnet", Loc("주간 · Sonnet", "Weekly · Sonnet"), .other),
            ("seven_day_opus", Loc("주간 · Opus", "Weekly · Opus"), .other),
            ("seven_day_oauth_apps", Loc("주간 · 앱", "Weekly · Apps"), .other),
        ]
        var windows: [UsageWindow] = []
        for item in labels {
            guard let w = json[item.key] as? [String: Any], let util = JSON.double(w["utilization"]) else { continue }
            windows.append(UsageWindow(id: item.key, label: item.label, kind: item.kind,
                                       usedFraction: util / 100, resetsAt: JSON.date(w["resets_at"])))
        }
        guard !windows.isEmpty else { throw UsageError.badResponse }

        let status = try? await authStatus()
        let plan = (status?["subscriptionType"] as? String) ?? creds.subscriptionType
        return ProviderUsage(provider: id, account: status?["email"] as? String,
                             plan: plan?.capitalized, windows: windows, updatedAt: Date())
    }

    private var runClaudeHint: Loc { Loc("터미널에서 claude를 한 번 실행하세요", "run claude once in Terminal") }

    private func requestUsage(token: String) async throws -> [String: Any] {
        try await HTTP.getJSON(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "claude-code/2.1.0",
        ])
    }

    private func readCredentials() async throws -> Credentials {
        let data: Data
        do {
            data = try await Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 15)
        } catch {
            throw UsageError.notLoggedIn(Loc("터미널에서 claude 로그인 필요", "sign in with claude in Terminal"))
        }
        guard let json = JSON.object(data),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw UsageError.notLoggedIn(Loc("Claude Code OAuth 정보 없음", "no Claude Code OAuth credentials")) }
        return Credentials(accessToken: token, expiresAt: JSON.date(oauth["expiresAt"]),
                           subscriptionType: oauth["subscriptionType"] as? String)
    }

    private func authStatus() async throws -> [String: Any]? {
        guard let claude = Shell.find("claude") else { return nil }
        return JSON.object(try await Shell.run(claude, ["auth", "status"], timeout: 20))
    }
}
