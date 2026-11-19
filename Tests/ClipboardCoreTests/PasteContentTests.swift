import Foundation
import Testing
import ClipboardCore

/// Chrome copies an image as PNG bytes plus an HTML fragment that is only
/// an <img> tag pointing at the remote original. Rich text views (Notes)
/// prefer the HTML, and the system's HTML importer can block forever
/// fetching that URL, hanging the app being pasted into.
@Suite struct PasteContentTests {
    let wrapper = typed(TypeName.html, "<meta charset='utf-8'><img src=\"https://example.com/a.png\">")
    let png = TypedData(type: TypeName.png, data: makePNG(width: 4, height: 4))
    let chromeToken = typed("org.chromium.source-url", "https://example.com/page")

    @Test func imageWithOnlyAnHTMLWrapperIsPastedWithoutTheHTML() {
        let copied = content(png, wrapper, chromeToken)
        let pasted = copied.forPasting
        #expect(!pasted.hasType(TypeName.html))
        #expect(pasted == content(png, chromeToken))
    }

    @Test func tiffImageIsTreatedTheSame() {
        let tiff = typed(TypeName.tiff, "tiff bytes")
        #expect(content(tiff, wrapper).forPasting == content(tiff))
    }

    @Test func textWithHTMLKeepsItsHTML() {
        let copied = content(typed(TypeName.plainText, "hello"), typed(TypeName.html, "<b>hello</b>"))
        #expect(copied.forPasting == copied)
    }

    @Test func imageThatAlsoHasTextKeepsItsHTML() {
        // Spreadsheet cells: text, an HTML table and a rendered picture.
        let copied = content(typed(TypeName.plainText, "1\t2"), typed(TypeName.html, "<table></table>"), png)
        #expect(copied.forPasting == copied)
    }

    @Test func plainImageIsUnchanged() {
        #expect(content(png).forPasting == content(png))
    }

    @Test @MainActor func pastingAnImageItemDoesNotWriteTheHTMLWrapper() {
        let pasteboard = FakePasteboard()
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store, sourceApp: { nil }, now: { at(0) })
        pasteboard.copy(content(png, wrapper, chromeToken))
        monitor.tick()
        monitor.paste(store.items[0], plainText: false)
        #expect(pasteboard.written == [content(png, chromeToken)])
        // The stored item keeps everything that was copied.
        #expect(store.fullContent(for: store.items[0].id) == content(png, wrapper, chromeToken))
    }
}
