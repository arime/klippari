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

/// Where the panel opens when it follows the mouse pointer: above the
/// pointer when the card fits there, otherwise below it, centred on the
/// pointer and kept on screen.
public struct PointerPlacement: Equatable, Sendable {
    /// Space between the pointer and the card's nearer edge.
    public static let gap: CGFloat = 12

    public var windowFrame: CGRect
    /// True when the card sits above the pointer. The card is then drawn
    /// at the bottom of the window, so that if the list grows while the
    /// panel is open it grows upward, away from the pointer.
    public var isAbovePointer: Bool

    /// `cardHeight` is the card's height for the list it opens with. The
    /// window is larger than the tallest card by `inset` on every side.
    public init(pointer: CGPoint, cardHeight: CGFloat, windowSize: CGSize, inset: CGFloat, in visible: CGRect) {
        self.init(
            anchor: CGRect(origin: pointer, size: .zero), cardHeight: cardHeight,
            windowSize: windowSize, inset: inset, in: visible
        )
    }

    /// The same, next to a rectangle rather than a point, such as the text
    /// field being typed in: above it when the card fits there, otherwise
    /// below it, centred on it sideways, never over it unless the screen
    /// leaves no other room.
    public init(anchor: CGRect, cardHeight: CGFloat, windowSize: CGSize, inset: CGFloat, in visible: CGRect) {
        let gap = Self.gap
        let cardWidth = windowSize.width - 2 * inset
        var cardCenterX = max(anchor.midX, visible.minX + cardWidth / 2)
        cardCenterX = min(cardCenterX, visible.maxX - cardWidth / 2)
        let x = (cardCenterX - windowSize.width / 2).rounded()

        let roomAbove = visible.maxY - (anchor.maxY + gap)
        if cardHeight <= roomAbove {
            isAbovePointer = true
            let cardBottom = anchor.maxY + gap
            windowFrame = CGRect(
                x: x, y: (cardBottom - inset).rounded(), width: windowSize.width, height: windowSize.height
            )
            return
        }

        isAbovePointer = false
        var cardTop = anchor.minY - gap
        // No room below either: keep the card on screen, over the pointer
        // if need be, with its top edge winning on a very short screen.
        cardTop = max(cardTop, visible.minY + cardHeight)
        cardTop = min(cardTop, visible.maxY)
        windowFrame = CGRect(
            x: x, y: (cardTop + inset - windowSize.height).rounded(),
            width: windowSize.width, height: windowSize.height
        )
    }
}

/// Where an enlarged image goes: beside the panel's card, never over it.
public enum PreviewPlacement {
    /// Space between the card and the preview.
    public static let gap: CGFloat = 12
    /// Space kept free at the screen's edges.
    public static let margin: CGFloat = 8
    public static let maxSize = CGSize(width: 320, height: 240)
    /// Below this on its longer side a preview is not worth showing,
    /// unless the image itself is that small.
    public static let minSide: CGFloat = 120

    private enum Side { case right, left, below, above }

    /// The preview's frame for an image of `imageSize` points beside
    /// `card`, scaled down to fit but never enlarged. It goes beside the
    /// card, on whichever side fits the larger preview (right on a tie),
    /// and below or above only when neither side has useful room. Beside
    /// the card it is centred on `rowMidY`, the highlighted row's middle,
    /// or without one its top lines up with the card's top;
    /// above or below, its left edge lines up with the card's. Nil when
    /// there is no useful room on any side.
    public static func frame(
        imageSize: CGSize, card: CGRect, rowMidY: CGFloat? = nil, in visible: CGRect
    ) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let inner = visible.insetBy(dx: margin, dy: margin)

        func room(_ side: Side) -> CGSize {
            switch side {
            case .right: CGSize(width: inner.maxX - card.maxX - gap, height: inner.height)
            case .left: CGSize(width: card.minX - gap - inner.minX, height: inner.height)
            case .below: CGSize(width: inner.width, height: card.minY - gap - inner.minY)
            case .above: CGSize(width: inner.width, height: inner.maxY - card.maxY - gap)
            }
        }
        func fitted(_ box: CGSize) -> CGSize {
            guard box.width > 0, box.height > 0 else { return .zero }
            let scale = min(
                min(box.width, maxSize.width) / imageSize.width,
                min(box.height, maxSize.height) / imageSize.height, 1
            )
            return CGSize(
                width: (imageSize.width * scale).rounded(.down),
                height: (imageSize.height * scale).rounded(.down)
            )
        }

        // Beside the card first, whatever the image's shape, so that
        // stepping through images does not make the preview jump sides.
        let worthShowing = min(minSide, max(imageSize.width, imageSize.height))
        func largest(_ sides: [Side]) -> (side: Side, size: CGSize)? {
            var best: (side: Side, size: CGSize)?
            for side in sides {
                let size = fitted(room(side))
                // Strictly larger, so ties go to the earlier side.
                if size.width * size.height > (best.map { $0.size.width * $0.size.height } ?? 0) {
                    best = (side, size)
                }
            }
            guard let best, max(best.size.width, best.size.height) >= worthShowing else { return nil }
            return best
        }
        guard let best = largest([.right, .left]) ?? largest([.below, .above]) else { return nil }

        let size = best.size
        let wantedY = rowMidY.map { $0 - size.height / 2 } ?? card.maxY - size.height
        let besideY = min(max(wantedY, inner.minY), inner.maxY - size.height)
        let stackedX = min(max(card.minX, inner.minX), inner.maxX - size.width)
        let origin: CGPoint = switch best.side {
        case .right: CGPoint(x: card.maxX + gap, y: besideY)
        case .left: CGPoint(x: card.minX - gap - size.width, y: besideY)
        case .below: CGPoint(x: stackedX, y: card.minY - gap - size.height)
        case .above: CGPoint(x: stackedX, y: card.maxY + gap)
        }
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
