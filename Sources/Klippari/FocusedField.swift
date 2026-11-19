import AppKit
import ApplicationServices
import os

/// Where the text being typed is on screen, read through Accessibility,
/// so the panel can open next to it rather than at the pointer.
@MainActor enum FocusedField {
    /// A text field taller than this is treated as an editor, and the
    /// panel goes next to the caret's line instead of the whole field.
    private static let maxFieldHeight: CGFloat = 200
    /// The longest one Accessibility call may wait for the front app.
    private static let messagingTimeout: Float = 0.25
    /// How long an Electron app gets to show its text fields after
    /// being asked to.
    private static let exposureBudget: TimeInterval = 0.25
    private static let manualAccessibility = "AXManualAccessibility" as CFString
    /// Set when a call timed out. The rest of the lookup is then skipped,
    /// so a busy app holds up opening the panel for one timeout, not one
    /// per attribute.
    private static var timedOut = false
    /// What each lookup found, at debug level, for apps where the panel
    /// lands in the wrong place: `log show --debug --predicate
    /// 'subsystem == "com.arime.Klippari" && category == "position"'`.
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "position")

    private enum Lookup {
        /// A text field has focus; nil when its frame cannot be used.
        case text(CGRect?)
        case notText
    }

    /// The rectangle, in screen coordinates (origin bottom left), to open
    /// the panel next to: the focused text field when it is a small one,
    /// or else the caret's line. Nil when neither can be read: without
    /// the Accessibility permission, with no text field focused, in an
    /// app that does not expose them, or when the app is too busy to
    /// answer in time.
    static func anchorFrame() -> CGRect? {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? "?"
        guard AXIsProcessTrusted() else {
            logger.debug("\(app, privacy: .public): no Accessibility permission, using the pointer")
            return nil
        }
        timedOut = false
        let system = AXUIElementCreateSystemWide()
        // Never hold up opening the panel for a slow app.
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        if case .text(let frame) = lookUp(system, app: app) { return frame }
        guard !timedOut, let front, let element = electronAppToExpose(front) else { return nil }

        // Electron apps, such as Slack, Discord or Claude, show their
        // text fields to Accessibility only after being asked to. Ask,
        // look again while the app builds them, and take the request
        // back, so the app is left as it was found.
        AXUIElementSetAttributeValue(element, manualAccessibility, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(element, manualAccessibility, kCFBooleanFalse) }
        let deadline = Date().addingTimeInterval(exposureBudget)
        while !timedOut, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
            if case .text(let frame) = lookUp(system, app: app) { return frame }
        }
        return nil
    }

    private static func lookUp(_ system: AXUIElement, app: String) -> Lookup {
        guard let focused = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            logger.debug("\(app, privacy: .public): no focused element, using the pointer")
            return .notText
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
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
            return .notText
        }

        if let field, field.height > 0, field.height <= maxFieldHeight {
            logger.debug("\(app, privacy: .public): using the field")
            return .text(toScreen(field))
        }
        if let caret, caret.height > 0 {
            logger.debug("\(app, privacy: .public): using the caret")
            return .text(toScreen(caret))
        }
        logger.debug("\(app, privacy: .public): no usable frame, using the pointer")
        return .text(nil)
    }

    /// The app's Accessibility element when it is an Electron app that
    /// has not been asked to show its text fields. Nil when it has, by
    /// the user or another tool: that setting is theirs and is left on.
    private static func electronAppToExpose(_ app: NSRunningApplication) -> AXUIElement? {
        guard let bundle = app.bundleURL,
              FileManager.default.fileExists(
                  atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
              )
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        if attribute(element, manualAccessibility as String) as? Bool == true { return nil }
        return timedOut ? nil : element
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard !timedOut else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .cannotComplete { timedOut = true }
        guard result == .success else { return nil }
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
        let result = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds
        )
        if result == .cannotComplete { timedOut = true }
        guard result == .success else { return nil }
        return rect(bounds)
    }

    /// Flips from Accessibility coordinates to screen coordinates.
    private static func toScreen(_ rect: CGRect) -> CGRect? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
