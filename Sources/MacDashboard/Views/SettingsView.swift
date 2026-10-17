import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
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
            Section("메뉴 막대") {
                Toggle("CPU 사용률", isOn: $menuCPU)
                Toggle("CPU 온도", isOn: $menuTemp)
                Toggle("메모리", isOn: $menuMemory)
                Toggle("SSD 사용률", isOn: $menuDisk)
                Toggle("네트워크 속도", isOn: $menuNetwork)
                Toggle("AI 사용량 배지", isOn: $menuUsage)
            }
            Section("AI 사용 한도") {
                Toggle("Claude (Claude Code 로그인)", isOn: $claudeOn)
                Toggle("ChatGPT (Codex 로그인)", isOn: $codexOn)
                Toggle("Gemini (Antigravity CLI)", isOn: $geminiOn)
                Picker("배지에 표시할 서비스", selection: $pinned) {
                    ForEach(ProviderID.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("표시 방식", selection: $mode) {
                    Text("사용량").tag("used")
                    Text("남은 양").tag("remaining")
                }
                Picker("자동 갱신 주기", selection: $interval) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { Text("\($0)분").tag($0) }
                }
                Toggle("계정 이메일 표시", isOn: $showAccount)
            }
            Section("일반") {
                Toggle("IP 주소 표시", isOn: $showIP)
                Toggle("로그인 시 자동 실행", isOn: Binding(
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
        .onChange(of: [menuCPU, menuMemory, menuNetwork, menuTemp, menuDisk, menuUsage]) { model.onTick?() }
        .onChange(of: [claudeOn, codexOn, geminiOn]) { model.refreshUsage(force: false) }
        .onChange(of: pinned) { model.onTick?() }
        .onChange(of: mode) { model.onTick?() }
    }
}
