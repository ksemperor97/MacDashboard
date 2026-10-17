import AppKit
import SwiftUI

/// Two status items: the AI usage badge and the system metrics strip. Each opens its own popover.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let systemItem: NSStatusItem
    private let usageItem: NSStatusItem
    private let systemPopover = NSPopover()
    private let usagePopover = NSPopover()
    private var lastSystemKey = ""
    private var lastUsageKey = ""
    var openSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        // Items added later sit further left, so the usage badge ends up left of the metrics.
        systemItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        usageItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        systemItem.autosaveName = "MacDashboard.system"
        usageItem.autosaveName = "MacDashboard.usage"

        for popover in [systemPopover, usagePopover] {
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
        }

        for (item, action) in [(systemItem, #selector(toggleSystem)), (usageItem, #selector(toggleUsage))] {
            item.button?.target = self
            item.button?.action = action
            item.button?.imagePosition = .imageOnly
        }
        update()
    }

    /// Popover content is created on open and dropped on close, so hidden SwiftUI views don't
    /// keep re-rendering on every sample.
    private func makeContent(for popover: NSPopover) -> NSViewController {
        let settings: () -> Void = { [weak self] in self?.showSettings() }
        let root = popover === systemPopover
            ? AnyView(SystemDashboardView(openSettings: settings).environment(model))
            : AnyView(UsageView(openSettings: settings).environment(model))
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        return host
    }

    // MARK: Popovers

    @objc private func toggleSystem() { toggle(systemPopover, from: systemItem) }

    @objc private func toggleUsage() {
        model.refreshUsageIfStale()
        toggle(usagePopover, from: usageItem)
    }

    private func toggle(_ popover: NSPopover, from item: NSStatusItem) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        [systemPopover, usagePopover].filter { $0 !== popover && $0.isShown }.forEach { $0.performClose(nil) }
        guard let button = item.button else { return }
        popover.contentViewController = makeContent(for: popover)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func open(_ which: String) {
        if which == "usage" { toggleUsage() } else { toggleSystem() }
    }

    private func showSettings() {
        systemPopover.performClose(nil)
        usagePopover.performClose(nil)
        openSettings?()
    }

    func popoverDidShow(_ notification: Notification) {
        model.popoverOpen = true
        if (notification.object as? NSPopover) === systemPopover { model.tick() }
    }

    func popoverDidClose(_ notification: Notification) {
        (notification.object as? NSPopover)?.contentViewController = nil
        model.popoverOpen = systemPopover.isShown || usagePopover.isShown
    }

    // MARK: Rendering

    func update() {
        systemItem.button?.setAccessibilityLabel(L.t("시스템 상태", "System Status"))
        usageItem.button?.setAccessibilityLabel(L.t("AI 사용 한도", "AI Usage Limits"))
        updateSystemItem()
        updateUsageItem()
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
            var columns: [StatusColumn] = showIcons ? [.icon(id.symbol)] : []
            let windows = model.usage[id]?.usage?.badgeWindows ?? []
            for w in windows {
                let used = w.effectiveUsed()
                columns.append(.metric(w.kind.short ?? "", Format.percent(remaining ? 1 - used : used)))
            }
            if windows.isEmpty {
                columns.append(.metric(showIcons ? "" : String(id.displayName.prefix(6)).uppercased(), "–"))
            }
            return columns
        }
        let key = groups.map { $0.map(\.key).joined(separator: "|") }.joined(separator: "#")
        guard key != lastUsageKey else { return }
        lastUsageKey = key
        usageItem.button?.image = groups.isEmpty
            ? StatusImage.render([[.metric("AI", "–")]], pill: true)
            : StatusImage.render(groups, pill: true)
    }
}

enum StatusColumn {
    case metric(String, String)      // small caption over a bold value
    case stacked(String, String)     // two equal small lines (network rates)
    case icon(String)                // SF Symbol identifying a service

    var key: String {
        switch self {
        case .metric(let a, let b): "m\(a)\(b)"
        case .stacked(let a, let b): "s\(a)\(b)"
        case .icon(let name): "i\(name)"
        }
    }
}

/// Draws status item contents as a template image so it follows the menu bar's light/dark tint.
/// Each group is drawn side by side; with `pill` every group gets its own rounded background.
enum StatusImage {
    static func render(_ groups: [[StatusColumn]], pill: Bool) -> NSImage {
        let caption = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let spacing: CGFloat = 8
        let iconSpacing: CGFloat = 5
        let groupGap: CGFloat = 4
        let padding: CGFloat = pill ? 7 : 1
        let height: CGFloat = 22

        func attrs(_ font: NSFont) -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.black] }
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: attrs(f)).width) }
        func symbol(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
        }

        // Fixed minimum widths keep the item from jittering as numbers change.
        func columnWidth(_ col: StatusColumn) -> CGFloat {
            switch col {
            case .metric(let c, let v): max(width(c, caption), width(v, value), width("100%", value))
            case .stacked(let a, let b): max(width(a, small), width(b, small), width("↑999K", small))
            case .icon(let name): ceil(symbol(name)?.size.width ?? 12)
            }
        }
        func gap(after col: StatusColumn) -> CGFloat {
            if case .icon = col { return iconSpacing }
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
                    NSColor.black.withAlphaComponent(0.16).setFill()
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
                    case .icon(let name):
                        if let img = symbol(name) {
                            let size = img.size
                            img.draw(in: NSRect(x: x + (w - size.width) / 2, y: (height - size.height) / 2,
                                                width: size.width, height: size.height))
                        }
                    }
                    x += w + gap(after: col)
                }
                groupX += layout.width + groupGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
