import AppKit
import SwiftUI

/// Status items for local AI speed, the AI usage badge and the system metrics strip, each with
/// its own popover.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let systemItem: NSStatusItem
    private let usageItem: NSStatusItem
    private let systemPopover = NSPopover()
    private let usagePopover = NSPopover()
    private let localItem: NSStatusItem
    private let localPopover = NSPopover()
    private var lastSystemKey = ""
    private var lastUsageKey = ""
    private var lastLocalKey = ""
    private var appearanceObservation: NSKeyValueObservation?
    private var menuBarIsDark: Bool?
    var openSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        // Items added later sit further left, so the usage badge ends up left of the metrics.
        systemItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        usageItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        localItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        localItem.autosaveName = "MacDashboard.localAI"
        systemItem.autosaveName = "MacDashboard.system"
        usageItem.autosaveName = "MacDashboard.usage"

        for popover in [systemPopover, usagePopover, localPopover] {
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
        }

        for (item, action) in [(systemItem, #selector(toggleSystem)), (usageItem, #selector(toggleUsage)),
                               (localItem, #selector(toggleLocal))] {
            item.button?.target = self
            item.button?.action = action
            item.button?.imagePosition = .imageOnly
        }
        // Colored badges draw their own text color, so redraw when the menu bar turns light/dark.
        // Setting the image can re-announce the same appearance, so only a real light/dark switch
        // triggers a redraw; otherwise this would loop and keep the CPU busy.
        appearanceObservation = usageItem.button?.observe(\.effectiveAppearance) { [weak self] button, _ in
            let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async {
                guard let self, isDark != self.menuBarIsDark else { return }
                self.menuBarIsDark = isDark
                self.update()
            }
        }
        update()
    }

    /// Popover content is created on open and dropped on close, so hidden SwiftUI views don't
    /// keep re-rendering on every sample.
    private func makeContent(for popover: NSPopover, screen: NSScreen?) -> NSViewController {
        let settings: () -> Void = { [weak self] in self?.showSettings() }
        let root: AnyView
        if popover === systemPopover {
            root = AnyView(SystemDashboardView(openSettings: settings).environment(model))
        } else if popover === localPopover {
            root = AnyView(LocalAIView(monitor: model.localAI, openSettings: settings).environment(model))
        } else {
            root = AnyView(UsageView(openSettings: settings).environment(model))
        }
        // Leave room for the popover arrow and margins above the Dock/visible screen edge.
        let maximumHeight = max(1, (screen?.visibleFrame.height ?? 700) - 24)
        let host = NSHostingController(rootView: HeightLimitedScrollView(
            width: popover === usagePopover ? 400 : 460, maximumHeight: maximumHeight
        ) { root })
        host.sizingOptions = .preferredContentSize
        return host
    }

    // MARK: Popovers

    @objc private func toggleSystem() { toggle(systemPopover, from: systemItem) }

    @objc private func toggleUsage() {
        model.refreshUsageIfStale()
        toggle(usagePopover, from: usageItem)
    }

    @objc private func toggleLocal() { toggle(localPopover, from: localItem) }

    private func toggle(_ popover: NSPopover, from item: NSStatusItem) {
        if popover.isShown {
            // A popover that reports shown but has no visible window is reopened instead of "closed".
            guard popover.contentViewController?.view.window?.isVisible != true else {
                popover.performClose(nil)
                return
            }
            popover.close()
        }
        [systemPopover, usagePopover, localPopover].filter { $0 !== popover && $0.isShown }.forEach { $0.performClose(nil) }
        guard let button = item.button else { return }
        popover.contentViewController = makeContent(for: popover, screen: button.window?.screen ?? NSScreen.main)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func open(_ which: String) {
        switch which {
        case "usage": toggleUsage()
        case "local": toggleLocal()
        default: toggleSystem()
        }
    }

    private func showSettings() {
        systemPopover.performClose(nil)
        usagePopover.performClose(nil)
        localPopover.performClose(nil)
        openSettings?()
    }

    func popoverDidShow(_ notification: Notification) {
        model.popoverOpen = true
        if (notification.object as? NSPopover) === systemPopover { model.tick() }
        if (notification.object as? NSPopover) === localPopover { model.localAI.popoverOpen = true }
    }

    func popoverDidClose(_ notification: Notification) {
        (notification.object as? NSPopover)?.contentViewController = nil
        model.popoverOpen = systemPopover.isShown || usagePopover.isShown || localPopover.isShown
        model.localAI.popoverOpen = localPopover.isShown
    }

    // MARK: Rendering

    func update() {
        systemItem.button?.setAccessibilityLabel(L.t("시스템 상태", "System Status"))
        usageItem.button?.setAccessibilityLabel(L.t("AI 사용 한도", "AI Usage Limits"))
        localItem.button?.setAccessibilityLabel(L.t("로컬 AI 속도", "Local AI speed"))
        updateSystemItem()
        updateUsageItem()
        updateLocalItem()
    }

    private func updateSystemItem() {
        let d = Prefs.d
        let s = model.snapshot
        var columns: [StatusColumn] = []
        if d.bool(forKey: Prefs.menuCPU) { columns.append(.metric("CPU", Format.percent(s.cpu.total))) }
        if d.bool(forKey: Prefs.menuTemp) { columns.append(.metric("TEMP", Format.temperature(model.sensors.cpuTemp))) }
        if d.bool(forKey: Prefs.menuMemory) { columns.append(.metric("MEM", Format.percent(s.memory.usedFraction))) }
        if d.bool(forKey: Prefs.menuDisk) { columns.append(.metric("SSD", Format.percent(s.disk.usedFraction))) }
        if d.bool(forKey: Prefs.menuNetwork) {
            columns.append(.stacked("↑" + Format.compactRate(s.network.upRate), "↓" + Format.compactRate(s.network.downRate)))
        }
        let key = columns.map(\.key).joined(separator: "|")
        guard key != lastSystemKey else { return }
        lastSystemKey = key
        systemItem.button?.image = columns.isEmpty
            ? NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "MacDashboard")
            : StatusImage.render([columns], pill: false)
    }

    /// "LLM / Idle" while nothing runs; "LLM / 16.2" (generation tok/s) while a model is working and
    /// for a few seconds after a request finishes. Shown only while a local engine is running.
    private func updateLocalItem() {
        let ai = model.localAI
        localItem.isVisible = Prefs.d.bool(forKey: Prefs.menuLocalAI) && ai.status != nil
        guard localItem.isVisible else { return }
        let justFinished = ai.lastFinishedAt.map { Date().timeIntervalSince($0) < 15 } ?? false
        let value: String
        if ai.isWorking || justFinished {
            // Engines don't report speed mid-request, so show the most recent typical request's.
            let speed = Format.speed(ai.headline?.generationTokensPerSecond)
            value = speed == "–" ? "…" : speed
        } else {
            value = ai.canDetermineActivity ? "Idle" : "–"
        }
        let column = StatusColumn.metric("LLM", value)
        guard column.key != lastLocalKey else { return }
        lastLocalKey = column.key
        localItem.button?.image = StatusImage.render([[column]], pill: false)
        localItem.button?.toolTip = ai.canDetermineActivity || ai.isWorking
            ? L.t("로컬 AI 생성 속도 (토큰/초) · 현재 모델의 최근 측정값", "Local AI generation speed (tokens/s) · latest measurement for this model")
            : L.t("로컬 AI · 다른 앱의 생성 상태를 확인할 수 없어요", "Local AI · activity from other apps is unknown")
    }

    private func updateUsageItem() {
        let d = Prefs.d
        usageItem.isVisible = d.bool(forKey: Prefs.menuUsage)
        guard usageItem.isVisible else { return }
        let remaining = Prefs.showRemaining
        var pinned = Prefs.pinned.filter(Prefs.isEnabled)
        if pinned.isEmpty { pinned = Array(model.enabledProviders.prefix(1)) }
        // With several services each gets its own pill, led by its icon so they can be told apart.
        let showIcons = pinned.count > 1
        let groups: [[StatusColumn]] = pinned.map { id in
            var columns: [StatusColumn] = showIcons ? [.logo(id)] : []
            let windows = model.usage[id]?.usage?.badgeWindows ?? []
            for w in windows {
                let used = w.effectiveUsed(updatedAt: model.usage[id]?.usage?.updatedAt ?? .distantPast)
                columns.append(.metric(w.kind.short ?? "", Format.percent(used.map { remaining ? 1 - $0 : $0 })))
            }
            if windows.isEmpty {
                columns.append(.metric(showIcons ? "" : String(id.displayName.prefix(6)).uppercased(), "–"))
            }
            return columns
        }
        // Several services: keep the icons in color, with text matching the menu bar's appearance.
        let tint = showIcons ? menuBarTextColor(for: usageItem.button) : nil
        let key = groups.map { $0.map(\.key).joined(separator: "|") }.joined(separator: "#") + "\(tint?.description ?? "")"
        guard key != lastUsageKey else { return }
        lastUsageKey = key
        usageItem.button?.image = groups.isEmpty
            ? StatusImage.render([[.metric("AI", "–")]], pill: true)
            : StatusImage.render(groups, pill: true, tint: tint)
    }

    private func menuBarTextColor(for button: NSStatusBarButton?) -> NSColor {
        var color = NSColor.black
        (button?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        return color
    }
}

enum StatusColumn {
    case metric(String, String)      // small caption over a bold value
    case stacked(String, String)     // two equal small lines (network rates)
    case logo(ProviderID)            // service icon identifying a badge group

    var key: String {
        switch self {
        case .metric(let a, let b): "m\(a)\(b)"
        case .stacked(let a, let b): "s\(a)\(b)"
        case .logo(let id): "l\(id.rawValue)"
        }
    }
}

/// Draws status item contents. Without `tint` it is a template image that follows the menu bar's
/// light/dark tint; with `tint` text uses that color and service icons keep their own colors.
/// Each group is drawn side by side; with `pill` every group gets its own rounded background.
enum StatusImage {
    static func render(_ groups: [[StatusColumn]], pill: Bool, tint: NSColor? = nil) -> NSImage {
        let ink = tint ?? .black
        let caption = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let logoSize: CGFloat = 14
        let spacing: CGFloat = 8
        let iconSpacing: CGFloat = 5
        let groupGap: CGFloat = 4
        let padding: CGFloat = pill ? 7 : 1
        let height: CGFloat = 22

        func attrs(_ font: NSFont) -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: ink] }
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: attrs(f)).width) }

        // Fixed minimum widths keep the item from jittering as numbers change.
        func columnWidth(_ col: StatusColumn) -> CGFloat {
            switch col {
            case .metric(let c, let v): max(width(c, caption), width(v, value), width("100%", value))
            case .stacked(let a, let b): max(width(a, small), width(b, small), width("↑999K", small))
            case .logo: logoSize
            }
        }
        func gap(after col: StatusColumn) -> CGFloat {
            if case .logo = col { return iconSpacing }
            return spacing
        }
        let layouts: [(columns: [StatusColumn], widths: [CGFloat], width: CGFloat)] = groups.map { columns in
            let widths = columns.map(columnWidth)
            let gaps = columns.dropLast().map(gap(after:)).reduce(0, +)
            return (columns, widths, widths.reduce(0, +) + gaps + padding * 2)
        }
        let total = layouts.map(\.width).reduce(0, +) + groupGap * CGFloat(max(layouts.count - 1, 0))

        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            var groupX: CGFloat = 0
            for layout in layouts {
                if pill {
                    ink.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: NSRect(x: groupX, y: 1.5, width: layout.width, height: height - 3),
                                 xRadius: 6, yRadius: 6).fill()
                }
                var x = groupX + padding
                for (col, w) in zip(layout.columns, layout.widths) {
                    func draw(_ s: String, _ f: NSFont, y: CGFloat) {
                        let sw = width(s, f)
                        (s as NSString).draw(at: NSPoint(x: x + (w - sw) / 2, y: y), withAttributes: attrs(f))
                    }
                    switch col {
                    case .metric(let c, let v):
                        draw(c, caption, y: 11.5)
                        draw(v, value, y: 0.5)
                    case .stacked(let a, let b):
                        draw(a, small, y: 10.5)
                        draw(b, small, y: 0.5)
                    case .logo(let id):
                        // Logos are defined y-down; flip into the image's y-up space.
                        if let ctx = NSGraphicsContext.current?.cgContext {
                            ctx.saveGState()
                            ctx.translateBy(x: x, y: (height + logoSize) / 2)
                            ctx.scaleBy(x: 1, y: -1)
                            ProviderLogo.draw(id, in: ctx, rect: CGRect(x: 0, y: 0, width: logoSize, height: logoSize),
                                              colored: tint != nil, ink: ink.cgColor)
                            ctx.restoreGState()
                        }
                    }
                    x += w + gap(after: col)
                }
                groupX += layout.width + groupGap
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}
