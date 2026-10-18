import Foundation

/// Gemini limits through the Antigravity CLI. `agy -p /quota` prints the quota report without
/// starting a model turn, so it costs no quota (takes a few seconds).
struct GeminiProvider: UsageProvider {
    let id = ProviderID.gemini

    func fetch() async throws -> ProviderUsage {
        guard let agy = AntigravityCLI.locate() else {
            throw UsageError.notInstalled(Loc("Antigravity CLI", "Antigravity CLI"))
        }
        let data: Data
        do {
            data = try await Shell.run(agy, ["-p", "/quota", "--output-format", "json"], timeout: 90)
        } catch ShellError.failed(_, let code, _) where code == 126 || code == 127 {
            throw UsageError.notInstalled(Loc("Antigravity CLI", "Antigravity CLI"))
        }
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
                let windowLabel = kind == .fiveHour ? WindowKind.fiveHourLabel
                    : (kind == .weekly ? WindowKind.weeklyLabel : Loc(window, window))
                // Only the main Gemini group drives the menu bar badge.
                let badgeKind: WindowKind = groupName == "Gemini" ? kind : .other
                groupWindows.append(UsageWindow(
                    id: bucket["id"] as? String ?? UUID().uuidString,
                    label: Loc("\(groupName) · \(windowLabel.ko)", "\(groupName) · \(windowLabel.en)"),
                    kind: badgeKind,
                    usedFraction: 1 - remaining,
                    resetsAt: JSON.date(bucket["reset_time"]),
                    hideWhenUnused: groupName == "Claude·GPT"
                ))
            }
            // Show the 5-hour window before the weekly one, like the other services.
            windows += groupWindows.sorted { ($0.label.en.hasSuffix("5 hours") ? 0 : 1) < ($1.label.en.hasSuffix("5 hours") ? 0 : 1) }
        }
        guard !windows.isEmpty else { throw UsageError.badResponse }
        return ProviderUsage(provider: id, account: nil, plan: nil, windows: windows, updatedAt: Date(), note: Loc("Antigravity 기준", "via Antigravity"))
    }

    private func shortName(_ name: String) -> String {
        switch name {
        case "Gemini Models": "Gemini"
        case "Claude and GPT models": "Claude·GPT"
        default: name
        }
    }
}

/// Finds the real Antigravity CLI. The Antigravity desktop app can leave an `agy` shell script that
/// launches /Applications/Antigravity.app (and breaks when the app is gone); that is not the CLI.
enum AntigravityCLI {
    /// Where MacDashboard 1.2.7 installed the CLI; still used if present.
    static var managedPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDashboard/antigravity-cli/antigravity").path
    }

    static func locate() -> String? {
        var candidates: [String] = []
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let room = "\(prefix)/Caskroom/antigravity-cli"
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: room)) ?? []).sorted(by: >)
            candidates += versions.map { "\(room)/\($0)/antigravity" }
        }
        candidates += Shell.searchPaths.map { "\($0)/agy" }
        candidates.append(managedPath)
        return candidates.first(where: isNativeExecutable)
    }

    /// An `agy` script that launches the Antigravity desktop app. It occupies the path Homebrew links
    /// the CLI to, so `brew install --cask antigravity-cli` fails until it is removed.
    static var desktopLauncherPath: String? {
        Shell.searchPaths.map { "\($0)/agy" }.first { path in
            guard !isNativeExecutable(path), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.hasPrefix("#!") && text.contains("Antigravity.app")
        }
    }

    /// The CLI is a native binary; the desktop app's launcher is a script.
    private static func isNativeExecutable(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let magic = [UInt8](handle.readData(ofLength: 4))
        return magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xBE, 0xBA, 0xFE, 0xCA]
    }
}

/// What the Gemini card should walk the user through when Antigravity isn't ready.
enum AntigravitySetup {
    enum Stage { case install, signIn }

    static func stage(for error: Error?) -> Stage? {
        guard let error else { return nil }
        if case UsageError.notInstalled = error { return .install }
        // agy has no dedicated "not signed in" error; recognise it from its message.
        if case ShellError.failed(_, _, let message) = error {
            let text = message.lowercased()
            let signIn = ["login", "log in", "sign in", "signin", "sign-in", "auth", "credential", "로그인"]
            if signIn.contains(where: text.contains) { return .signIn }
        }
        return nil
    }
}
