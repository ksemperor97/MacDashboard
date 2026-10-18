import AppKit
import SwiftUI

/// Step-by-step help on the Gemini card when the Antigravity CLI isn't installed or signed in.
/// MacDashboard doesn't install anything itself; it shows the recommended commands, links to the
/// alternatives, and connects on its own once the CLI works (see `AppModel.watchAntigravitySetup`).
struct AntigravityGuide: View {
    let stage: AntigravitySetup.Stage
    let onCheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stage == .install {
                Step(number: 1, text: L.t("Antigravity CLI를 설치해요. Homebrew를 권장해요.",
                                          "Install the Antigravity CLI. Homebrew is recommended."))
                CommandRow(command: "brew install --cask antigravity-cli")
                if let launcher = AntigravityCLI.desktopLauncherPath {
                    Text(L.t("\(launcher)는 Antigravity 데스크톱 앱이 만든 실행 파일이라 Homebrew 설치와 충돌해요. 앱을 쓰지 않는다면 먼저 지워 주세요.",
                             "\(launcher) was created by the Antigravity desktop app and blocks the Homebrew install. If you don't use the app, remove it first."))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandRow(command: "rm \(launcher)")
                }
                HStack(spacing: 6) {
                    Link(L.t("Homebrew 설치", "Get Homebrew"), destination: URL(string: "https://brew.sh")!)
                    Text("·").foregroundStyle(.secondary)
                    Link(L.t("다른 설치 방법", "Other ways to install"),
                         destination: URL(string: "https://antigravity.google/product/antigravity-cli")!)
                }
                .font(.system(size: 10))
            }
            Step(number: stage == .install ? 2 : 1,
                 text: L.t("터미널에서 agy를 실행해 Google 계정으로 로그인한 뒤 /exit 를 입력해요.",
                           "Run agy in Terminal, sign in with your Google account, then type /exit."))
            CommandRow(command: "agy")
            Step(number: stage == .install ? 3 : 2,
                 text: L.t("끝나면 MacDashboard가 몇 초 안에 알아서 연결해요.",
                           "When you're done, MacDashboard connects by itself within a few seconds."))
            HStack(spacing: 8) {
                Button(L.t("터미널 열기", "Open Terminal")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
                Button(L.t("지금 확인", "Check now"), action: onCheck)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16, height: 16)
                .background(.primary.opacity(0.1), in: Circle())
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L.t("복사", "Copy"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.leading, 22)
    }
}
