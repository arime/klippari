import Foundation
import Testing
import ClipboardCore

@MainActor final class FakePasteboard: PasteboardClient {
    var changeCount = 0
    var current = ClipContent(entries: [])
    var written: [ClipContent] = []

    /// Simulates another app copying something.
    func copy(_ content: ClipContent) {
        current = content
        changeCount += 1
    }

    func read() -> ClipContent { current }

    func write(_ content: ClipContent) -> Int {
        written.append(content)
        current = content
        changeCount += 1
        return changeCount
    }
}

@MainActor @Suite struct ClipboardMonitorTests {
    let pasteboard = FakePasteboard()
    let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))

    func makeMonitor(sourceApp: String? = "Notes") -> ClipboardMonitor {
        ClipboardMonitor(pasteboard: pasteboard, store: store, sourceApp: { sourceApp }, now: { at(0) })
    }

    @Test func capturesOnChange() {
        let monitor = makeMonitor(sourceApp: "Safari")
        pasteboard.copy(text("hello"))
        monitor.tick()
        #expect(store.items.map(\.content) == [text("hello")])
        #expect(store.items[0].sourceApp == "Safari")
    }

    @Test func ignoresUnchangedCount() {
        let monitor = makeMonitor()
        pasteboard.copy(text("hello"))
        monitor.tick()
        monitor.tick()
        #expect(store.items.count == 1)
    }

    @Test func doesNotCaptureContentPresentAtLaunch() {
        pasteboard.copy(text("already there"))
        let monitor = makeMonitor()
        monitor.tick()
        #expect(store.items.isEmpty)
    }

    @Test func skipsConcealed() {
        let monitor = makeMonitor()
        pasteboard.copy(content(typed(TypeName.plainText, "hunter2"), typed("org.nspasteboard.ConcealedType", "")))
        monitor.tick()
        #expect(store.items.isEmpty)
        pasteboard.copy(text("ordinary"))
        monitor.tick()
        #expect(store.items.map(\.content) == [text("ordinary")])
    }

    @Test func pausedDoesNotCaptureNorCatchUp() {
        let monitor = makeMonitor()
        monitor.isPaused = true
        pasteboard.copy(text("while paused"))
        monitor.tick()
        monitor.isPaused = false
        monitor.tick()
        #expect(store.items.isEmpty)
        pasteboard.copy(text("after resume"))
        monitor.tick()
        #expect(store.items.map(\.content) == [text("after resume")])
    }

    @Test func pausedWithoutTickDoesNotCatchUp() {
        let monitor = makeMonitor()
        monitor.isPaused = true
        pasteboard.copy(text("while paused"))
        monitor.isPaused = false
        monitor.tick()
        #expect(store.items.isEmpty)
    }

    @Test func pasteDoesNotCreateNewItem() {
        let monitor = makeMonitor()
        pasteboard.copy(text("b"))
        monitor.tick()
        pasteboard.copy(text("a"))
        monitor.tick()
        let b = store.items[1]
        monitor.paste(b, plainText: false)
        monitor.tick()
        #expect(store.items.map(\.content) == [text("b"), text("a")])
        #expect(pasteboard.written == [text("b")])
    }

    @Test func plainPasteWritesOnlyPlainText() {
        let monitor = makeMonitor()
        let styled = content(typed(TypeName.plainText, "hi"), typed(TypeName.rtf, "{rtf}"))
        pasteboard.copy(styled)
        monitor.tick()
        monitor.paste(store.items[0], plainText: true)
        monitor.tick()
        #expect(pasteboard.written == [text("hi")])
        #expect(store.items.map(\.content) == [styled.lightened])
        #expect(store.fullContent(for: store.items[0].id) == styled)
    }

    @Test func plainPasteOfImageWritesOriginal() {
        let monitor = makeMonitor()
        let image = content(TypedData(type: TypeName.png, data: makePNG(width: 2, height: 2)))
        pasteboard.copy(image)
        monitor.tick()
        monitor.paste(store.items[0], plainText: true)
        #expect(pasteboard.written == [image])
    }
}
