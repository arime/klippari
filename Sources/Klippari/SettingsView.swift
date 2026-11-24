import AppKit
import Carbon.HIToolbox
import ClipboardCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    /// The app's version, from its Info.plist. Nil when the binary runs
    /// outside an app bundle, and then the line is left out.
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    @State private var startsAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var shortcutRejected = false

    /// Shown under the field only when something went wrong.
    private var shortcutProblem: String? {
        if shortcutRejected {
            return "That combination is a standard command (copy, paste, quit…). Try another."
        }
        if settings.shortcutUnavailable {
            return "That shortcut could not be registered, so the previous one was kept."
        }
        return nil
    }

    private var limit: Binding<Int> {
        Binding(
            get: { settings.historyLimit },
            set: { settings.historyLimit = min(max($0, Settings.limitRange.lowerBound), Settings.limitRange.upperBound) }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            form
            if let version {
                Text("Klippari \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { startsAtLogin = LoginItem.isEnabled }
    }

    private var form: some View {
        Form {
            LabeledContent("Keep last") {
                HStack(spacing: 6) {
                    TextField("", value: limit, format: .number)
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: limit, in: Settings.limitRange)
                        .labelsHidden()
                    Text("items")
                }
            }

            LabeledContent("Shortcut") {
                VStack(alignment: .leading, spacing: 4) {
                    ShortcutRecorder(shortcut: $settings.shortcut, rejected: $shortcutRejected)
                        .frame(width: 130, height: 24)
                        // The form lines labels up on text baselines, and
                        // a custom view has none, which left 'Shortcut'
                        // sitting above the field. Report the baseline of
                        // the text drawn in the field's middle instead.
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    if let shortcutProblem {
                        Text(shortcutProblem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            LabeledContent("Start at login") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("", isOn: Binding(
                        get: { startsAtLogin },
                        set: { setStartsAtLogin($0) }
                    ))
                    .labelsHidden()
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            LabeledContent("Mouse") {
                Toggle("Point to select, click to paste", isOn: $settings.mouseOnRows)
            }
            // The rows fall into three groups (essentials, panel options,
            // cleared history); a little extra space sets them apart.
            .padding(.top, 10)

            LabeledContent("Position") {
                Toggle("Open at context (cursor fallback)", isOn: $settings.openAtPointer)
            }

            LabeledContent("Images") {
                Toggle("Enlarge the selected image", isOn: $settings.magnifyImages)
            }

            // Only there when something was cleared, so Settings stays
            // short in everyday use.
            if let archive = settings.archive {
                LabeledContent("Cleared history") {
                    VStack(alignment: .leading, spacing: 6) {
                        // The summary gets a line of its own: beside the
                        // buttons it wrapped onto two. No year: nothing
                        // stays cleared for more than a day.
                        Text("\(archive.count == 1 ? "1 item" : "\(archive.count) items"), "
                            + (archive.clears == 1 ? "cleared " : "last cleared ")
                            + archive.archivedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .fixedSize()
                        HStack(spacing: 8) {
                            Button("Restore") { settings.onRestoreArchive?() }
                            Button("Delete", role: .destructive) { settings.onDeleteArchive?() }
                        }
                        if let note = settings.restoreNote {
                            Text(note)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Each clear is deleted 24 hours after it was made.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func setStartsAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
        }
        startsAtLogin = LoginItem.isEnabled
    }
}

/// A focusable field that takes the next key combination pressed while
/// it has focus as the new shortcut. It is a plain view rather than a
/// button so Tab reaches it whatever the system keyboard-navigation
/// setting is.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    /// True after a reserved combination was refused.
    @Binding var rejected: Bool

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = {
            rejected = false
            shortcut = $0
        }
        view.onReject = { rejected = true }
        view.label = shortcut.displayString
    }

    final class RecorderView: NSView {
        var onRecord: ((Shortcut) -> Void)?
        var onReject: (() -> Void)?
        var label = "" { didSet { needsDisplay = true } }
        /// Recording has to be started on purpose (Return, Space or a
        /// click). Otherwise pressing Cmd+W or Cmd+Q while the field merely
        /// has focus would silently become the global shortcut.
        private var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds }

        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }

        override func becomeFirstResponder() -> Bool {
            needsDisplay = true
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        /// Returns true when the event was consumed by recording.
        private func record(_ event: NSEvent) -> Bool {
            guard isRecording, window?.firstResponder === self else { return false }
            if Int(event.keyCode) == kVK_Escape {
                isRecording = false
                return true
            }
            guard let shortcut = Shortcut(event: event) else { return false }
            let modifiers = shortcut.carbonModifiers
            let reserved = ShortcutPolicy.isReserved(
                keyCode: shortcut.keyCode,
                command: modifiers & UInt32(cmdKey) != 0, control: modifiers & UInt32(controlKey) != 0,
                option: modifiers & UInt32(optionKey) != 0, shift: modifiers & UInt32(shiftKey) != 0
            )
            if reserved {
                // Stay in recording mode so another combination can be tried.
                onReject?()
            } else {
                isRecording = false
                onRecord?(shortcut)
            }
            return true
        }

        /// Combinations with Cmd arrive here first; taking them stops a
        /// menu item (Cmd+Q, Cmd+W) from firing while recording.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            record(event) || super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if record(event) { return }
            let key = Int(event.keyCode)
            if !isRecording, key == kVK_Return || key == kVK_Space {
                isRecording = true
                return
            }
            // Other bare keys (Tab) fall through so focus can move on.
            super.keyDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            ]
            let label = isRecording ? "Press shortcut…" : label
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

/// Owns the settings window. Opening it activates the app, which a
/// background (accessory) app otherwise never does.
@MainActor final class SettingsWindowController {
    private let settings: Settings
    private var window: NSWindow?

    init(settings: Settings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Klippari Settings"
            window.isReleasedWhenClosed = false
            // The window follows the content's size, which changes when
            // the Cleared history row comes and goes.
            let hosting = NSHostingController(rootView: SettingsView(settings: settings))
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
