import AppKit
import Carbon.HIToolbox
import ClipboardCore
import SwiftUI

/// A panel that takes keyboard focus without activating this app, so the
/// app the user was in stays frontmost and receives the paste.
private final class HistoryPanel: NSPanel {
    /// Returns true when it handled the key.
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Intercept before the filter field sees the key, so arrows,
        // Return and Esc drive the list rather than the text cursor.
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Bumped on every show so the view can put focus back in the filter.
@MainActor @Observable final class PanelFocus {
    var showCount = 0
}

@MainActor final class PanelController: NSObject, NSWindowDelegate {
    private let model: PanelModel
    private let panel: HistoryPanel
    private let focus = PanelFocus()
    private let settings: Settings
    /// Where the app last put the window itself, to tell its own moves
    /// from the user dragging the panel.
    private var placedOrigin: NSPoint?

    /// Called with the chosen item and whether to paste it as plain text.
    var onPaste: ((ClipItem, _ plainText: Bool) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(model: PanelModel, storage: ItemStorage, settings: Settings) {
        self.model = model
        self.settings = settings
        panel = HistoryPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Like Spotlight, the panel can be dragged by any part of the card
        // that is not a control, and reopens where it was left.
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is drawn by the SwiftUI content, which is smaller
        // than the window and changes height with the list.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: PanelView(model: model, focus: focus, storage: storage)
        )
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    func show() {
        model.open()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // The remembered spot is relative to the screen, so the panel
            // still opens on the screen being used.
            let frame = (settings.panelPlacement ?? .default).windowFrame(
                windowSize: PanelMetrics.windowSize, inset: PanelMetrics.shadowInset, in: visible
            )
            placedOrigin = frame.origin
            panel.setFrame(frame, display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        focus.showCount += 1
    }

    /// Remembers where the user dragged the panel.
    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, panel.frame.origin != placedOrigin,
              let visible = panel.screen?.visibleFrame
        else { return }
        placedOrigin = panel.frame.origin
        settings.panelPlacement = PanelPlacement(
            windowFrame: panel.frame, inset: PanelMetrics.shadowInset, in: visible
        )
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = Int(event.keyCode)

        switch key {
        case kVK_Escape:
            if model.escape() == .close { hide() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard flags.isSubset(of: [.shift]) else { return false }
            if let item = model.selectedItem {
                onPaste?(item, flags.contains(.shift))
            }
            return true
        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_ANSI_N where flags == [.control]:
            model.moveSelection(by: 1)
            return true
        case kVK_ANSI_P where flags == [.control]:
            model.moveSelection(by: -1)
            return true
        case kVK_Delete where flags == [.command]:
            model.deleteSelected()
            return true
        default:
            break
        }

        if flags == [.command], let number = Self.digitKeys[key] {
            if let item = model.item(quickNumber: number) {
                onPaste?(item, false)
            }
            return true
        }
        return false
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]
}
