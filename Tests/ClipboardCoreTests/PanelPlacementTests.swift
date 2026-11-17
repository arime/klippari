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
}
