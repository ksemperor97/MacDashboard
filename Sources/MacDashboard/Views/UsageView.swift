import AppKit
import SwiftUI

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.usageMode) private var mode = "used"
    @AppStorage(Prefs.pinnedProviders) private var pinnedRaw = ""
    @AppStorage(Prefs.showAccount) private var showAccount = true
    @AppStorage(Prefs.language) private var language = AppLanguage.system.rawValue
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.enabledProviders.isEmpty {
                Text(L.t("설정에서 표시할 서비스를 켜 주세요", "Turn on a service in Settings"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 10) {
                    ForEach(model.enabledProviders) { id in
                        ProviderCard(id: id, state: model.usage[id] ?? UsageState(), now: context.date,
                                     remaining: mode == "remaining", showAccount: showAccount,
                                     pinned: Prefs.pinned(from: pinnedRaw).contains(id)) { Prefs.togglePinned(id) }
                    }
                }
            }
            Divider().padding(.horizontal, 4)
            HStack {
                FooterButton(icon: "gearshape", title: L.t("설정…", "Settings…"), action: openSettings)
                Spacer()
                FooterButton(icon: "power", title: L.t("종료", "Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 400)
        .id(language)
        .onChange(of: mode) { model.onTick?() }
        .onChange(of: pinnedRaw) { model.onTick?() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L.t("사용 한도", "Usage Limits")).font(.system(size: 15, weight: .bold))
            Spacer()
            Picker("", selection: $mode) {
                Text(L.t("사용량", "Used")).tag("used")
                Text(L.t("남은 양", "Remaining")).tag("remaining")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                model.refreshUsage(force: true)
            } label: {
                if model.isRefreshingUsage {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)).frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .help(L.t("지금 새로고침", "Refresh now"))
        }
        .padding(.horizontal, 2)
    }
}

private struct ProviderCard: View {
    let id: ProviderID
    let state: UsageState
    let now: Date
    let remaining: Bool
    let showAccount: Bool
    let pinned: Bool
    let onPin: () -> Void

    var body: some View {
        Card(highlight: pinned ? .orange : nil) {
            HStack(spacing: 6) {
                ProviderIcon(id: id)
                Text(id.displayName).font(.system(size: 14, weight: .semibold))
                if showAccount, let account = state.usage?.account {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let plan = state.usage?.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ProviderIcon.color(id).opacity(0.18), in: Capsule())
                        .foregroundStyle(ProviderIcon.color(id))
                }
                Button(action: onPin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(pinned ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(L.t("메뉴 막대 배지에 표시/해제", "Show in menu bar badge"))
            }

            if let usage = state.usage {
                ForEach(usage.windows.filter { $0.isVisible(at: now) }) { w in
                    WindowRow(window: w, now: now, remaining: remaining)
                }
                HStack(spacing: 4) {
                    Text(L.t("업데이트 ", "Updated ") + Format.clock(usage.updatedAt))
                    if let note = usage.note { Text("· " + note.text) }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                if let error = state.error {
                    Label(L.t("갱신 실패: ", "Refresh failed: ") + error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            } else if let error = state.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L.t("\(id.sourceName)에서 불러오는 중…", "Loading from \(id.sourceName)…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date
    let remaining: Bool

    var body: some View {
        let used = window.effectiveUsed(at: now)
        let shown = remaining ? 1 - used : used
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label.text).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(shown)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            ProgressBar(fraction: shown, color: Palette.level(used), height: 5)
            Text(Format.resetText(window.resetsAt, now: now))
                .font(.system(size: 11, weight: .medium))
        }
    }
}

struct ProviderIcon: View {
    let id: ProviderID

    static func color(_ id: ProviderID) -> Color {
        switch id {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.5)
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }

    var body: some View {
        Image(systemName: id.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Self.color(id))
            .frame(width: 18)
    }
}
