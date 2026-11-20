import CoreGraphics
import Foundation
import Testing
import ClipboardCore

@Suite struct PanelPlacementTests {
    // A window 760 × 600 whose card is inset 60 on every side: the card
    // is 640 wide and at most 480 tall.
    let windowSize = CGSize(width: 760, height: 600)
    let inset: CGFloat = 60
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func cardTop(_ frame: CGRect) -> CGFloat { frame.maxY - inset }
    func cardCenterX(_ frame: CGRect) -> CGFloat { frame.midX }

    @Test func defaultIsCentredAQuarterOfTheWayDown() {
        let frame = PanelPlacement.default.windowFrame(windowSize: windowSize, inset: inset, in: screen)
        #expect(frame.size == windowSize)
        #expect(cardCenterX(frame) == 800)
        #expect(cardTop(frame) == 750)
    }

    @Test func roundTripsAMovedWindow() {
        let moved = CGRect(x: 100, y: 300, width: 760, height: 600)
        let placement = PanelPlacement(windowFrame: moved, inset: inset, in: screen)
        #expect(placement.windowFrame(windowSize: windowSize, inset: inset, in: screen) == moved)
    }

    @Test func keepsTheSameRelativeSpotOnAnotherScreen() {
        let moved = CGRect(x: 20, y: 300, width: 760, height: 600) // card centre x 400, top 840
        let placement = PanelPlacement(windowFrame: moved, inset: inset, in: screen)
        #expect(placement.centerX == 0.25)
        #expect(abs(placement.top - 0.16) < 0.0001)

        let other = CGRect(x: 1600, y: 200, width: 3200, height: 2000)
        let frame = placement.windowFrame(windowSize: windowSize, inset: inset, in: other)
        #expect(cardCenterX(frame) == 2400) // a quarter of the way across
        #expect(cardTop(frame) == 1880)     // 16% of the way down
    }

    @Test func cardIsKeptFullyOnScreen() {
        let offLeftAndTop = PanelPlacement(centerX: -0.5, top: -0.5)
        let a = offLeftAndTop.windowFrame(windowSize: windowSize, inset: inset, in: screen)
        #expect(cardCenterX(a) == 320) // card's left edge at the screen edge
        #expect(cardTop(a) == 1000)

        let offRightAndBottom = PanelPlacement(centerX: 2, top: 2)
        let b = offRightAndBottom.windowFrame(windowSize: windowSize, inset: inset, in: screen)
        #expect(cardCenterX(b) == 1280) // card's right edge at the screen edge
        #expect(cardTop(b) == 480) // the tallest card still ends at the bottom edge
    }

    @Test func aScreenShorterThanTheCardPinsItToTheTop() {
        let short = CGRect(x: 0, y: 0, width: 1600, height: 300)
        let frame = PanelPlacement(centerX: 0.5, top: 0.9)
            .windowFrame(windowSize: windowSize, inset: inset, in: short)
        #expect(cardTop(frame) == 300)
    }

    @Test func codableRoundTrip() throws {
        let placement = PanelPlacement(centerX: 0.3, top: 0.6)
        let data = try JSONEncoder().encode(placement)
        #expect(try JSONDecoder().decode(PanelPlacement.self, from: data) == placement)
    }

    // MARK: Opening at the pointer

    func atPointer(_ x: CGFloat, _ y: CGFloat, cardHeight: CGFloat = 200, in visible: CGRect? = nil) -> PointerPlacement {
        PointerPlacement(
            pointer: CGPoint(x: x, y: y), cardHeight: cardHeight,
            windowSize: windowSize, inset: inset, in: visible ?? screen
        )
    }

    func cardBottom(_ frame: CGRect) -> CGFloat { frame.minY + inset }

    @Test func opensAboveThePointerWhenThereIsRoom() {
        let p = atPointer(800, 400)
        #expect(p.isAbovePointer)
        #expect(cardBottom(p.windowFrame) == 400 + PointerPlacement.gap)
        #expect(cardCenterX(p.windowFrame) == 800)
        #expect(p.windowFrame.size == windowSize)
    }

    @Test func opensBelowThePointerNearTheTop() {
        let p = atPointer(800, 900) // 100 to the top, card is 200
        #expect(!p.isAbovePointer)
        #expect(cardTop(p.windowFrame) == 900 - PointerPlacement.gap)
    }

    @Test func roomIsMeasuredWithTheCardItOpensWith() {
        // 100 points above the pointer: a short card fits, a tall one not.
        #expect(atPointer(800, 900, cardHeight: 80).isAbovePointer)
        #expect(!atPointer(800, 900, cardHeight: 200).isAbovePointer)
    }

    @Test func pointerPlacementStaysOnScreenSideways() {
        #expect(cardCenterX(atPointer(10, 400).windowFrame) == 320)
        #expect(cardCenterX(atPointer(1590, 400).windowFrame) == 1280)
    }

    @Test func aCardThatFitsNeitherAboveNorBelowStaysOnScreen() {
        let short = CGRect(x: 0, y: 0, width: 1600, height: 300)
        let p = atPointer(800, 150, cardHeight: 250, in: short)
        #expect(!p.isAbovePointer)
        #expect(cardTop(p.windowFrame) == 250)
        #expect(cardTop(p.windowFrame) - 250 >= short.minY)
    }

    @Test func opensAboveOrBelowATextFieldWithoutCoveringIt() {
        // A one-line input near the bottom of the screen.
        let field = CGRect(x: 200, y: 20, width: 1200, height: 40)
        let above = PointerPlacement(anchor: field, cardHeight: 200, windowSize: windowSize, inset: inset, in: screen)
        #expect(above.isAbovePointer)
        #expect(cardBottom(above.windowFrame) == field.maxY + PointerPlacement.gap)
        #expect(cardCenterX(above.windowFrame) == field.midX)

        // The same input at the top: the card goes below it.
        let high = CGRect(x: 200, y: 940, width: 1200, height: 40)
        let below = PointerPlacement(anchor: high, cardHeight: 200, windowSize: windowSize, inset: inset, in: screen)
        #expect(!below.isAbovePointer)
        #expect(cardTop(below.windowFrame) == high.minY - PointerPlacement.gap)
    }

    @Test func pointerPlacementOnASecondScreen() {
        let right = CGRect(x: 1600, y: 0, width: 1000, height: 800)
        let p = atPointer(2000, 300, in: right)
        #expect(p.isAbovePointer)
        #expect(cardCenterX(p.windowFrame) == 2000)
    }

    // MARK: Enlarged image beside the card

    let card = CGRect(x: 480, y: 400, width: 640, height: 300) // on the 1600 × 1000 screen

    func preview(_ size: CGSize, card: CGRect? = nil, in visible: CGRect? = nil) -> CGRect? {
        PreviewPlacement.frame(imageSize: size, card: card ?? self.card, in: visible ?? screen)
    }

    @Test func previewGoesRightOfTheCardWithTopsAligned() throws {
        let frame = try #require(preview(CGSize(width: 300, height: 200)))
        #expect(frame == CGRect(x: 1132, y: 500, width: 300, height: 200))
        #expect(!frame.intersects(card))
    }

    @Test func previewIsCentredOnTheHighlightedRow() throws {
        let frame = try #require(PreviewPlacement.frame(
            imageSize: CGSize(width: 300, height: 200), card: card, rowMidY: 450, in: screen
        ))
        #expect(frame.midY == 450)
        #expect(frame.minX == card.maxX + PreviewPlacement.gap)
        // Near the bottom of the screen it is kept on screen.
        let low = try #require(PreviewPlacement.frame(
            imageSize: CGSize(width: 300, height: 200), card: card, rowMidY: 20, in: screen
        ))
        #expect(low.minY == PreviewPlacement.margin)
    }

    @Test func previewIsScaledDownToTheRoomButNeverEnlarged() throws {
        let big = try #require(preview(CGSize(width: 2000, height: 1000)))
        #expect(big.size == CGSize(width: 320, height: 160))
        // Right of the card there are only 1600 - 8 - 1120 - 12 = 60 points.
        let cramped = CGRect(x: 900, y: 400, width: 640, height: 300)
        let left = try #require(preview(CGSize(width: 2000, height: 1000), card: cramped))
        #expect(left.maxX == 900 - PreviewPlacement.gap)
        let small = try #require(preview(CGSize(width: 50, height: 40)))
        #expect(small.size == CGSize(width: 50, height: 40))
    }

    @Test func previewTakesTheLeftWhenTheCardIsAtTheRightEdge() throws {
        let atRight = CGRect(x: 950, y: 400, width: 640, height: 300)
        let frame = try #require(preview(CGSize(width: 300, height: 200), card: atRight))
        #expect(frame.maxX == 950 - PreviewPlacement.gap)
        #expect(!frame.intersects(atRight))
    }

    @Test func previewGoesBelowOrAboveOnANarrowScreen() throws {
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 1000)
        let high = CGRect(x: 30, y: 650, width: 640, height: 300)
        let frame = try #require(preview(CGSize(width: 600, height: 400), card: high, in: narrow))
        #expect(frame.maxY == 650 - PreviewPlacement.gap)
        #expect(frame.minX == 30)
        #expect(!frame.intersects(high))
    }

    @Test func previewStaysOnScreenVertically() throws {
        let low = CGRect(x: 480, y: 8, width: 640, height: 100)
        let frame = try #require(preview(CGSize(width: 300, height: 400), card: low))
        #expect(frame.minY == PreviewPlacement.margin)
    }

    @Test func noPreviewWithoutRoom() {
        let tight = CGRect(x: 0, y: 0, width: 660, height: 320)
        #expect(preview(CGSize(width: 600, height: 400), card: CGRect(x: 10, y: 10, width: 640, height: 300), in: tight) == nil)
    }
}
