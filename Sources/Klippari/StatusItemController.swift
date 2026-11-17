import AppKit

/// The menu bar icon and its menu.
@MainActor final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: Settings
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")

    var onClearHistory: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onResetPanelPosition: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init()

        statusItem.button?.image = Self.makeIcon()

        let menu = NSMenu()
        menu.delegate = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(item("Clear History", #selector(clearHistory)))
        menu.addItem(item("Reset Panel Position", #selector(resetPanelPosition)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Klippari", #selector(quit), key: "q"))
        statusItem.menu = menu
        refresh()
    }

    /// The app icon's three rows, as a menu bar glyph. It is a template
    /// image, so macOS tints it for light and dark menu bars; that rules
    /// out the blue, and the top row stands out by opacity instead.
    static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let rowWidth: CGFloat = 14
            let rowHeight: CGFloat = 3.5
            let gap: CGFloat = 2
            let total = 3 * rowHeight + 2 * gap
            let alphas: [CGFloat] = [1, 0.55, 0.3] // top to bottom
            for (index, alpha) in alphas.enumerated() {
                let y = (size.height + total) / 2 - rowHeight - CGFloat(index) * (rowHeight + gap)
                let row = NSRect(x: (size.width - rowWidth) / 2, y: y, width: rowWidth, height: rowHeight)
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: row, xRadius: 1.2, yRadius: 1.2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Klippari"
        return image
    }

    /// Dims the icon while capture is paused.
    func refresh() {
        statusItem.button?.appearsDisabled = settings.isPaused
        pauseItem.title = settings.isPaused ? "Resume Capture" : "Pause Capture"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() {
        settings.isPaused.toggle()
    }

    @objc private func clearHistory() {
        onClearHistory?()
    }

    @objc private func resetPanelPosition() {
        onResetPanelPosition?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
