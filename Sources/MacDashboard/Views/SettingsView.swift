import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.language) private var language = AppLanguage.system.rawValue
    @AppStorage(Prefs.menuCPU) private var menuCPU = true
    @AppStorage(Prefs.menuMemory) private var menuMemory = true
    @AppStorage(Prefs.menuNetwork) private var menuNetwork = true
    @AppStorage(Prefs.menuTemp) private var menuTemp = false
    @AppStorage(Prefs.menuDisk) private var menuDisk = false
    @AppStorage(Prefs.menuUsage) private var menuUsage = true
    @AppStorage(Prefs.pinnedProvider) private var pinned = ProviderID.claude.rawValue
    @AppStorage(Prefs.usageMode) private var mode = "used"
    @AppStorage(Prefs.usageInterval) private var interval = 5
    @AppStorage(Prefs.showAccount) private var showAccount = true
    @AppStorage(Prefs.showIP) private var showIP = true
    @AppStorage(Prefs.enabled(.claude)) private var claudeOn = true
    @AppStorage(Prefs.enabled(.codex)) private var codexOn = true
    @AppStorage(Prefs.enabled(.gemini)) private var geminiOn = true

    var body: some View {
        Form {
            Section(L.t("메뉴 막대", "Menu Bar")) {
                Toggle(L.t("CPU 사용률", "CPU usage"), isOn: $menuCPU)
                Toggle(L.t("CPU 온도", "CPU temperature"), isOn: $menuTemp)
                Toggle(L.t("메모리", "Memory"), isOn: $menuMemory)
                Toggle(L.t("SSD 사용률", "SSD usage"), isOn: $menuDisk)
                Toggle(L.t("네트워크 속도", "Network speed"), isOn: $menuNetwork)
                Toggle(L.t("AI 사용량 배지", "AI usage badge"), isOn: $menuUsage)
            }
            Section(L.t("AI 사용 한도", "AI Usage Limits")) {
                Toggle(L.t("Claude (Claude Code 로그인)", "Claude (Claude Code login)"), isOn: $claudeOn)
                Toggle(L.t("ChatGPT (Codex 로그인)", "ChatGPT (Codex login)"), isOn: $codexOn)
                Toggle("Gemini (Antigravity CLI)", isOn: $geminiOn)
                Picker(L.t("배지에 표시할 서비스", "Service shown in badge"), selection: $pinned) {
                    ForEach(ProviderID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker(L.t("표시 방식", "Display"), selection: $mode) {
                    Text(L.t("사용량", "Used")).tag("used")
                    Text(L.t("남은 양", "Remaining")).tag("remaining")
                }
                Picker(L.t("자동 갱신 주기", "Refresh interval"), selection: $interval) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { Text(L.t("\($0)분", "\($0) min")).tag($0) }
                }
                Toggle(L.t("계정 이메일 표시", "Show account email"), isOn: $showAccount)
            }
            Section(L.t("일반", "General")) {
                Picker(L.t("언어 (Language)", "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.pickerLabel).tag($0.rawValue) }
                }
                Toggle(L.t("IP 주소 표시", "Show IP address"), isOn: $showIP)
                Toggle(L.t("로그인 시 자동 실행", "Launch at login"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let loginError = model.loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .id(language)
        .onChange(of: [menuCPU, menuMemory, menuNetwork, menuTemp, menuDisk, menuUsage]) { model.onTick?() }
        .onChange(of: [claudeOn, codexOn, geminiOn]) { model.refreshUsage(force: false) }
        .onChange(of: pinned) { model.onTick?() }
        .onChange(of: mode) { model.onTick?() }
        .onChange(of: language) { model.onTick?() }
    }
}
