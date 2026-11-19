import AppKit
import ApplicationServices
import os

/// Where the text being typed is on screen, read through Accessibility,
/// so the panel can open next to it rather than at the pointer.
@MainActor enum FocusedField {
    /// A text field taller than this is treated as an editor, and the
    /// panel goes next to the caret's line instead of the whole field.
    private static let maxFieldHeight: CGFloat = 200
    /// Electron apps already asked to expose their text fields.
    private static var enabledApps: Set<pid_t> = []
    /// What each lookup found, at debug level, for apps where the panel
    /// lands in the wrong place: `log show --debug --predicate
    /// 'subsystem == "com.arime.Klippari" && category == "position"'`.
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "position")

    /// The rectangle, in screen coordinates (origin bottom left), to open
    /// the panel next to: the focused text field when it is a small one,
    /// or else the caret's line. Nil when neither can be read: without
    /// the Accessibility permission, with no text field focused, or in an
    /// app that does not expose them.
    static func anchorFrame() -> CGRect? {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard AXIsProcessTrusted() else {
            logger.debug("\(app, privacy: .public): no Accessibility permission, using the pointer")
            return nil
        }
        let system = AXUIElementCreateSystemWide()
        // Never hold up opening the panel for a slow app.
        AXUIElementSetMessagingTimeout(system, 0.15)

        guard let focused = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            logger.debug("\(app, privacy: .public): no focused element, using the pointer")
            exposeElectronFields()
            return nil
        }
        let element = focused as! AXUIElement
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let field = frame(of: element)
        let caret = caretFrame(of: element)
        logger.debug("""
            \(app, privacy: .public): role \(role ?? "-", privacy: .public) \
            subrole \(subrole ?? "-", privacy: .public) \
            frame \(field.map { "\($0)" } ?? "-", privacy: .public) \
            caret \(caret.map { "\($0)" } ?? "-", privacy: .public)
            """)
        let isText = caret != nil
            || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
        guard isText else {
            logger.debug("\(app, privacy: .public): not a text field, using the pointer")
            exposeElectronFields()
            return nil
        }

        if let field, field.height > 0, field.height <= maxFieldHeight {
            logger.debug("\(app, privacy: .public): using the field")
            return toScreen(field)
        }
        if let caret, caret.height > 0 {
            logger.debug("\(app, privacy: .public): using the caret")
            return toScreen(caret)
        }
        logger.debug("\(app, privacy: .public): no usable frame, using the pointer")
        return nil
    }

    /// Electron apps, such as Slack, Discord or Claude, show their text
    /// fields to Accessibility only after being asked to. Ask the
    /// frontmost one once; it takes effect from the next open.
    private static func exposeElectronFields() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !enabledApps.contains(app.processIdentifier),
              let bundle = app.bundleURL,
              FileManager.default.fileExists(
                  atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
              )
        else { return }
        enabledApps.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, true as CFBoolean)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func point(_ value: CFTypeRef?) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(value), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ value: CFTypeRef?) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(value), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        var rect = CGRect.zero
        guard let value = axValue(value), AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The element's frame in Accessibility coordinates (origin top left
    /// of the main screen).
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = point(attribute(element, kAXPositionAttribute)),
              let size = size(attribute(element, kAXSizeAttribute))
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The caret's line, or the selection, in Accessibility coordinates.
    private static func caretFrame(of element: AXUIElement) -> CGRect? {
        guard let range = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds
        ) == .success else { return nil }
        return rect(bounds)
    }

    /// Flips from Accessibility coordinates to screen coordinates.
    private static func toScreen(_ rect: CGRect) -> CGRect? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
