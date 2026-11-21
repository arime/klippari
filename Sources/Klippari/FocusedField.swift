import AppKit
import ApplicationServices
import os

/// Where the text being typed is on screen, read through Accessibility,
/// so the panel can open next to it rather than at the pointer.
@MainActor enum FocusedField {
    /// A text field taller than this is treated as an editor, and the
    /// panel goes next to the caret's line instead of the whole field.
    private static let maxFieldHeight: CGFloat = 200
    /// The longest the whole lookup may take. Past it the panel opens at
    /// the pointer.
    private static let budget: TimeInterval = 0.2
    /// When the current lookup must be done by.
    private static var deadline = Date.distantPast
    /// Set when a call timed out or the time is up. The rest of the
    /// lookup is then skipped.
    private static var timedOut = false
    /// What each lookup found, at debug level, for apps where the panel
    /// lands in the wrong place: `log show --debug --predicate
    /// 'subsystem == "com.arime.Klippari" && category == "position"'`.
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "position")

    /// The rectangle, in screen coordinates (origin bottom left), to open
    /// the panel next to: the focused text field when it is a small one,
    /// or else the caret's line. Nil when neither can be read: without
    /// the Accessibility permission, with no text field focused, in an
    /// app that does not expose them, or when the app is too busy to
    /// answer in time.
    ///
    /// Electron apps, such as Slack, Discord or Claude, expose their text
    /// fields only while an assistive app such as VoiceOver has asked for
    /// them. Klippari does not ask (`AXManualAccessibility`): the fields
    /// appear only about two seconds later, far past the lookup's time,
    /// and asking makes the app keep its whole accessibility tree up to
    /// date, which costs it time and memory and can change how it
    /// behaves. In those apps the panel opens at the pointer.
    static func anchorFrame() -> CGRect? {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard AXIsProcessTrusted() else {
            logger.debug("\(app, privacy: .public): no Accessibility permission, using the pointer")
            return nil
        }
        timedOut = false
        deadline = Date().addingTimeInterval(budget)
        return lookUp(AXUIElementCreateSystemWide(), app: app)
    }

    private static func lookUp(_ system: AXUIElement, app: String) -> CGRect? {
        guard let focused = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            logger.debug("\(app, privacy: .public): no focused element, using the pointer")
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
        // A caret marks a text field only when it has a height: with
        // VoiceOver running, Electron apps give buttons an empty one.
        let isText = (caret?.height ?? 0) > 0
            || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
        guard isText else {
            logger.debug("\(app, privacy: .public): not a text field, using the pointer")
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

    /// Lets the next call on `element` wait only for what is left of
    /// the lookup's time. False, and the lookup is over, when none is.
    private static func setsTimeout(on element: AXUIElement) -> Bool {
        guard !timedOut else { return false }
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else {
            timedOut = true
            return false
        }
        AXUIElementSetMessagingTimeout(element, Float(left))
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard setsTimeout(on: element) else { return nil }
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
        guard let range = attribute(element, kAXSelectedTextRangeAttribute),
              setsTimeout(on: element)
        else { return nil }
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
