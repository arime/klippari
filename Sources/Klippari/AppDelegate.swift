import AppKit
import ClipboardCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var store: HistoryStore!
    private var monitor: ClipboardMonitor!
    private var model: PanelModel!
    private var panel: PanelController!
    private var hotKey: HotKey!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var registeredShortcut: Shortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let storage = ItemStorage(root: ItemStorage.defaultRoot)
        store = HistoryStore(storage: storage, limit: settings.historyLimit)
        monitor = ClipboardMonitor(
            pasteboard: SystemPasteboard(), store: store,
            sourceApp: { NSWorkspace.shared.frontmostApplication?.localizedName }
        )
        // PanelModel takes over store.onChange; nothing else may set it.
        model = PanelModel(store: store)
        panel = PanelController(model: model, storage: storage, settings: settings)
        panel.onPaste = { [weak self] item, plainText in
            self?.paste(item, plainText: plainText)
        }
        panel.onClearAll = { [weak self] in self?.clearFromPanel() }
        hotKey = HotKey(shortcut: settings.shortcut) { [weak self] in
            self?.hotKeyPressed()
        }
        registeredShortcut = settings.shortcut
        settings.shortcutUnavailable = !hotKey.isRegistered

        settingsWindow = SettingsWindowController(settings: settings)
        statusItem = StatusItemController(settings: settings)
        statusItem.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        statusItem.onResetPanelPosition = { [weak self] in self?.settings.panelPlacement = nil }
        settings.onChange = { [weak self] in self?.applySettings() }
        settings.onRestoreArchive = { [weak self] in self?.restoreArchive() }
        settings.archive = store.archiveSummary

        NSApp.mainMenu = makeMainMenu()
        LoginItem.registerOnFirstLaunch()
        monitor.start()
    }

    private func applySettings() {
        if store.limit != settings.historyLimit {
            store.limit = settings.historyLimit
        }
        if registeredShortcut != settings.shortcut {
            hotKey.update(settings.shortcut)
            if hotKey.isRegistered {
                registeredShortcut = settings.shortcut
                settings.shortcutUnavailable = false
            } else if let previous = registeredShortcut {
                // Never leave the app with no way to open the panel: go
                // back to the shortcut that worked. Setting it re-enters
                // this method, where the two now match and nothing happens.
                hotKey.update(previous)
                settings.shortcut = previous
                settings.shortcutUnavailable = true
            }
        }
        if monitor.isPaused != settings.isPaused {
            monitor.isPaused = settings.isPaused
        }
        statusItem.refresh()
    }

    /// The shortcut opens the panel; pressed again while it is open, it
    /// steps down the list so the modifiers can be held and V tapped.
    private func hotKeyPressed() {
        if panel.isVisible {
            model.moveSelection(by: 1)
        } else {
            panel.show()
        }
    }

    private func paste(_ item: ClipItem, plainText: Bool) {
        monitor.paste(item, plainText: plainText)
        guard Paster.isTrusted else {
            // Without Accessibility the item is on the clipboard but cannot
            // be pasted for the user; keep the panel open to say so.
            model.notice = "Copied. Klippari needs Accessibility to paste directly."
            model.noticeLink = Paster.accessibilitySettingsURL
            Paster.requestTrustOnce()
            return
        }
        panel.hide()
        // Let the previous app become key again before the keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Paster.sendPaste()
        }
    }

    private func confirmClearHistory() {
        let count = store.items.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This clears \(count == 1 ? "1 item" : "all \(count) items"). "
            + "Settings can restore them until the history is cleared again."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            archiveHistory()
        }
    }

    /// Shift+Cmd+Backspace in the panel: no confirmation, since the
    /// cleared history can be restored; the notice says how.
    private func clearFromPanel() {
        let count = archiveHistory()
        guard count > 0 else { return }
        model.notice = "Cleared \(count == 1 ? "1 item" : "\(count) items"). Restore them in Settings."
        model.noticeLink = nil
    }

    /// Clears the history into the archive, replacing the last one.
    @discardableResult
    private func archiveHistory() -> Int {
        let count = store.archiveAll(now: Date())
        settings.archive = store.archiveSummary
        return count
    }

    private func restoreArchive() {
        store.restoreArchive()
        settings.archive = store.archiveSummary
    }

    /// A background app has no visible menu bar, but the main menu still
    /// supplies the standard shortcuts (Cmd+Q, Cmd+W, Cmd+V in text
    /// fields) to the settings window and the filter field.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Klippari", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}
