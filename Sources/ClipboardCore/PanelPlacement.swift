import CoreGraphics
import Foundation

/// Where the panel's card sits on a screen, as fractions of that screen's
/// visible area. Storing fractions rather than points means a position
/// the user dragged the panel to carries over to whichever screen the
/// panel next opens on, whatever its size.
public struct PanelPlacement: Codable, Equatable, Sendable {
    /// Horizontal centre of the card: 0 at the left edge, 1 at the right.
    public var centerX: Double
    /// Top edge of the card: 0 at the top of the screen, 1 at the bottom.
    public var top: Double

    /// Centred, a quarter of the way down.
    public static let `default` = PanelPlacement(centerX: 0.5, top: 0.25)

    public init(centerX: Double, top: Double) {
        self.centerX = centerX
        self.top = top
    }

    /// The placement that corresponds to a window the user has moved. The
    /// window is larger than the card by `inset` on every side (a
    /// transparent margin that holds the card's shadow).
    public init(windowFrame: CGRect, inset: CGFloat, in visible: CGRect) {
        let cardTop = windowFrame.maxY - inset
        centerX = visible.width > 0 ? Double((windowFrame.midX - visible.minX) / visible.width) : 0.5
        top = visible.height > 0 ? Double((visible.maxY - cardTop) / visible.height) : 0.25
    }

    /// The window frame for this placement on a screen, in whole points,
    /// moved as little as needed to keep the card fully on screen. The
    /// card's height varies with the list, so the tallest card is what is
    /// kept on screen; on a screen too short for that, the top wins.
    public func windowFrame(windowSize: CGSize, inset: CGFloat, in visible: CGRect) -> CGRect {
        let cardWidth = windowSize.width - 2 * inset
        let maxCardHeight = windowSize.height - 2 * inset

        var cardCenterX = visible.minX + CGFloat(centerX) * visible.width
        cardCenterX = max(cardCenterX, visible.minX + cardWidth / 2)
        cardCenterX = min(cardCenterX, visible.maxX - cardWidth / 2)

        var cardTop = visible.maxY - CGFloat(top) * visible.height
        cardTop = max(cardTop, visible.minY + maxCardHeight)
        cardTop = min(cardTop, visible.maxY)

        return CGRect(
            x: (cardCenterX - windowSize.width / 2).rounded(),
            y: (cardTop + inset - windowSize.height).rounded(),
            width: windowSize.width, height: windowSize.height
        )
    }
}
