import Foundation

/// Tells when to peek in Presentation Mode: tap Option alone, then press
/// it again and hold it a moment with no key. Typing a character that
/// needs Option (@ on a Finnish keyboard) does not peek after resting on
/// Option, nor after a quick tap of Option with the key typed at once:
/// the key comes within the hold. Only a tap and then a pause on the
/// second press peeks before the key.
///
/// Times are seconds on one clock, such as `NSEvent.timestamp`.
public struct PeekGesture: Sendable {
    /// How quick the tap must be, and how soon the second press follows.
    public static let window: TimeInterval = 0.35
    /// How long the second press is held, with no key, before the peek
    /// shows: longer than the gap between Option and the key it types.
    public static let hold: TimeInterval = 0.15

    /// When Option alone went down, while no key has been pressed since.
    private var pressedAt: TimeInterval?
    /// When a clean tap ended, while the second press may still come.
    private var tappedAt: TimeInterval?
    /// When the second press went down: the peek shows once it has been
    /// held for `hold`.
    public private(set) var armedAt: TimeInterval?
    /// Whether every modifier was up at the last change. A press counts
    /// only from there: Option left down after Shift or Cmd lets go
    /// was not pressed alone, and a key may have come with the chord.
    private var wasNone = true

    public init() {}

    /// The modifiers changed. `optionAlone` is Option down with no other
    /// modifier; `none` is every modifier up. The peek, if one was
    /// showing, ends; call `shouldPeek(at:)` after `hold` to start one.
    public mutating func modifiersChanged(optionAlone: Bool, none: Bool, at now: TimeInterval) {
        defer { wasNone = none }
        if optionAlone {
            guard wasNone else {
                pressedAt = nil
                tappedAt = nil
                armedAt = nil
                return
            }
            if let tappedAt, now - tappedAt <= Self.window {
                self.tappedAt = nil
                pressedAt = nil
                armedAt = now
            } else {
                pressedAt = now
                tappedAt = nil
                armedAt = nil
            }
            return
        }
        if none, let pressedAt, now - pressedAt <= Self.window {
            tappedAt = now
        } else {
            tappedAt = nil
        }
        pressedAt = nil
        armedAt = nil
    }

    /// A key was pressed, the shortcut among them: the peek ends, and no
    /// tap counts across it.
    public mutating func keyPressed() {
        pressedAt = nil
        tappedAt = nil
        armedAt = nil
    }

    /// Whether the second press has now been held long enough to peek.
    public func shouldPeek(at now: TimeInterval) -> Bool {
        guard let armedAt else { return false }
        return now - armedAt >= Self.hold
    }
}
