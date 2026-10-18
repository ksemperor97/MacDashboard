import AppKit
import Foundation

/// One-click setup for a service that isn't installed or signed in on this Mac.
/// Writes a small script and opens it in Terminal: the script explains what it will do, waits for
/// Enter, installs the CLI if it's missing (Homebrew, else the vendor's installer), then starts the
/// CLI's own sign-in (which opens the browser). The app polls until the service responds.
enum ProviderConnector {
    /// Errors that a connect (install and/or sign-in) can fix.
    /// Errors that a connect (install and/or sign-in) can fix. Gemini isn't handled here: its card
    /// shows `AntigravityGuide` so the user installs the CLI the way they prefer.
    static func canConnect(_ id: ProviderID, error: Error?) -> Bool {
        guard id != .gemini, let error else { return false }
        if let usageError = error as? UsageError {
            switch usageError {
            case .notInstalled, .notLoggedIn, .tokenExpired: return true
            case .http(401), .http(403): return true
            default: break
            }
        }
        return false
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDashboard", isDirectory: true)
    }

    static func scriptURL(for id: ProviderID) -> URL { directory.appendingPathComponent("connect-\(id.rawValue).command") }
    private static func startedMarker(for id: ProviderID) -> URL { directory.appendingPathComponent("connect-\(id.rawValue).started") }

    static func openSetup(for id: ProviderID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: startedMarker(for: id))
        let url = scriptURL(for: id)
        try script(for: id).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        Task { await launchInTerminal(url) }
    }

    /// Opening a .command makes Terminal type its path into a brand-new shell, and on some Macs the
    /// first character gets swallowed ("Users/…: no such file"). So Terminal is driven directly: open
    /// a window, give the shell time to start, then send the command padded with spaces so a lost
    /// character is harmless. This asks once for permission to control Terminal; if that's denied
    /// or fails, fall back to opening the .command.
    private static func launchInTerminal(_ url: URL) async {
        let command = "        bash '\(url.path)'"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            set setupTab to do script ""
            delay 1.5
            do script "\(command)" in setupTab
        end tell
        """
        do {
            _ = try await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        } catch {
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The script leaves a marker as its first step; without it the card offers to copy the command.
    static func didStart(_ id: ProviderID) -> Bool {
        FileManager.default.fileExists(atPath: startedMarker(for: id).path)
    }

    static func copyCommand(for id: ProviderID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("bash '\(scriptURL(for: id).path)'", forType: .string)
    }

    // MARK: Scripts

    private static func script(for id: ProviderID) -> String {
        let title = L.t("MacDashboard · \(id.displayName) 연결", "MacDashboard · Connect \(id.displayName)")
        let steps: [String]
        let body: String
        switch id {
        case .claude:
            steps = [
                L.t("Claude Code가 없으면 설치해요 (Homebrew 또는 공식 설치 스크립트)",
                    "Install Claude Code if it's missing (Homebrew or the official installer)"),
                L.t("브라우저에서 Claude 계정으로 로그인해요", "Sign in with your Claude account in the browser"),
            ]
            body = """
            if ! command -v claude >/dev/null 2>&1; then
              if command -v brew >/dev/null 2>&1; then
                brew install --cask claude-code
              else
                curl -fsSL https://claude.ai/install.sh | bash
                export PATH="$HOME/.local/bin:$PATH"
              fi
            fi
            require claude
            claude auth login --claudeai
            """
        case .codex:
            steps = [
                L.t("Codex CLI가 없으면 설치해요 (Homebrew 또는 npm)", "Install the Codex CLI if it's missing (Homebrew or npm)"),
                L.t("브라우저에서 ChatGPT 계정으로 로그인해요", "Sign in with your ChatGPT account in the browser"),
            ]
            body = """
            if ! command -v codex >/dev/null 2>&1; then
              if command -v brew >/dev/null 2>&1; then
                brew install --cask codex
              elif command -v npm >/dev/null 2>&1; then
                npm install -g @openai/codex
              else
                need_homebrew
              fi
            fi
            require codex
            codex login
            """
        case .gemini:
            return ""  // Gemini uses the in-card AntigravityGuide instead of a setup script
        }

        let numbered = steps.enumerated().map { "echo \"  \($0.offset + 1). \(escape($0.element))\"" }.joined(separator: "\n")
        return """
        #!/bin/bash
        # Generated by MacDashboard. Safe to delete; it is rewritten each time you click Connect.
        touch "\(escape(startedMarker(for: id).path))"
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

        require() {
          if ! command -v "$1" >/dev/null 2>&1; then
            echo
            echo "\(escape(L.t("설치에 실패했어요. 위 메시지를 확인해 주세요.", "Installation failed. Check the messages above.")))"
            read -r -p "\(escape(L.t("Enter를 누르면 닫혀요", "Press Enter to close")))"
            exit 1
          fi
        }

        fail() {
          echo
          echo "\(escape(L.t("설치에 실패했어요. 위 메시지를 확인해 주세요.", "Installation failed. Check the messages above.")))"
          read -r -p "\(escape(L.t("Enter를 누르면 닫혀요", "Press Enter to close")))"
          exit 1
        }

        need_homebrew() {
          echo
          echo "\(escape(L.t("Homebrew가 필요해요. https://brew.sh 에서 설치한 뒤 다시 연결하기를 눌러 주세요.",
                            "Homebrew is required. Install it from https://brew.sh, then click Connect again.")))"
          open "https://brew.sh"
          read -r -p "\(escape(L.t("Enter를 누르면 닫혀요", "Press Enter to close")))"
          exit 1
        }

        clear
        echo "\(escape(title))"
        echo
        echo "\(escape(L.t("이 창에서 다음을 진행해요:", "This window will:")))"
        \(numbered)
        echo
        read -r -p "\(escape(L.t("Enter를 누르면 시작해요 (취소하려면 창을 닫으세요) ", "Press Enter to start (close the window to cancel) ")))"
        echo

        \(body)

        echo
        echo "\(escape(L.t("완료! MacDashboard가 잠시 후 자동으로 갱신해요. 이 창은 닫아도 돼요.",
                          "Done! MacDashboard will update in a moment. You can close this window.")))"
        """
    }

    /// Escapes text for a double-quoted bash string.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
