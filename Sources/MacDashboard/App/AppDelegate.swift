import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusBar: StatusBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        let controller = StatusBarController(model: model)
        controller.openSettings = { [weak self] in self?.showSettings() }
        statusBar = controller
        model.onTick = { [weak controller] in controller?.update() }
        model.start()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSettingsTitle() }
        }

        // `--open system|usage|settings` opens a panel right after launch (handy when checking the UI).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let target = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if target == "settings" { self.showSettings() } else { controller.open(target) }
            }
        }
    }

    private func updateSettingsTitle() {
        let title = L.t("MacDashboard 설정", "MacDashboard Settings")
        if settingsWindow?.title != title { settingsWindow?.title = title }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(model))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        updateSettingsTitle()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
