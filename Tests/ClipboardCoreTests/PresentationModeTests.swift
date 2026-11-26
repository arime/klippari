import CryptoKit
import Foundation
import Testing
import ClipboardCore

/// Presentation Mode: rows show what kind of item each is, never what it
/// holds, and the filter matches only what rows show.
@Suite struct PresentationModeTests {
    let key = SymmetricKey(size: .bits256)

    func hidden(_ content: ClipContent, sourceApp: String? = "Notes", imageInfo: ImageInfo? = nil) -> RowPresentation {
        RowPresentation(makeItem(content, sourceApp: sourceApp, imageInfo: imageInfo), hidingContents: true, markerKey: key)
    }

    @Test func textShowsOnlyItsKindAndLineCount() {
        let one = hidden(text("hunter2-but-longer"))
        #expect(one.title == "Text")
        #expect(one.tag == nil)
        #expect(one.peek == "hunter…")
        #expect(!one.searchText.contains("hunter"))
        #expect(one.matches("text"))
        #expect(one.matches("notes"))
        #expect(!one.matches("hunter"))
        let three = hidden(text("first line\nsecond\nthird"))
        #expect(three.title == "Text")
        #expect(three.tag == "3 lines")
        #expect(three.peek == "first …")
    }

    @Test func styledTextAndLinks() {
        let styled = hidden(content(typed(TypeName.plainText, "Meeting notes"), typed(TypeName.rtf, "{rtf}")))
        #expect(styled.title == "Styled text")
        #expect(styled.tag == nil)
        let link = hidden(text("https://www.example.com/private/path"))
        #expect(link.title == "Link")
        #expect(link.tag == nil)
        #expect(link.peek == "exampl…")
        #expect(hidden(text("HTTPS://WWW.Example.com/x")).peek == "Exampl…")
        #expect(!link.matches("example"))
    }

    @Test func filesShowTheirTypesFromTheirNamesAlone() {
        // The files need not exist: rows never touch them, as reading
        // even a size in Documents makes macOS ask for access.
        let pdf = URL(fileURLWithPath: "/Users/someone/Documents/Quarterly salaries.pdf")
        let png = URL(fileURLWithPath: "/Volumes/Share/chart.png")
        let one = hidden(content(typed(TypeName.fileURL, pdf.absoluteString), typed(TypeName.plainText, pdf.lastPathComponent)))
        #expect(one.title == "File")
        #expect(one.tag == "pdf")
        #expect(one.peek == "Quarte…")
        #expect(!one.matches("salaries"))
        #expect(one.matches("pdf"))
        let two = hidden(ClipContent(entries: [
            PasteboardEntry(types: [typed(TypeName.fileURL, pdf.absoluteString)]),
            PasteboardEntry(types: [typed(TypeName.fileURL, png.absoluteString)]),
        ]))
        #expect(two.title == "2 files")
        #expect(two.tag == "pdf, png")
        #expect(!two.matches("chart"))
    }

    @Test func onlyKnownTypesShowAndFoldersSaySo() {
        // The part after a dot in a name is not a type unless the system
        // knows it as one.
        let named = hidden(content(typed(TypeName.fileURL, "file:///tmp/Clients.AcmeMerger")))
        #expect(named.tag == nil)
        #expect(!named.matches("acme"))
        let folder = hidden(content(typed(TypeName.fileURL, "file:///tmp/Projects/")))
        #expect(folder.title == "Folder")
        #expect(folder.tag == nil)
    }

    @Test func imagesShowSizeAndFormatButNoPeek() {
        let image = hidden(content(typed(TypeName.png, "png")), imageInfo: ImageInfo(width: 1280, height: 720, format: "PNG"))
        #expect(image.title == "Image")
        #expect(image.tag == "1280 × 720 · PNG")
        #expect(image.peek == nil)
    }

    @Test func aSecretShowsNotEvenItsMaskedLine() {
        var item = makeItem(text(fakeAnthropicKey))
        item.expiresAt = Date(timeIntervalSince1970: 2000)
        let row = RowPresentation(item, hidingContents: true, markerKey: key)
        #expect(row.title == "Secret")
        #expect(row.tag == nil)
        #expect(row.peek == nil)
        #expect(!row.matches("sk-ant"))
        #expect(row.matches("secret"))
        // One colour for every secret, so the same one copied again
        // looks no different from another.
        #expect(row.marker == .secret)
        var other = makeItem(text("sk-ant-api03-" + String(repeating: "b", count: 90)))
        other.expiresAt = Date(timeIntervalSince1970: 2000)
        #expect(RowPresentation(other, hidingContents: true, markerKey: key).marker == .secret)
        #expect(hidden(text("ordinary")).marker != .secret)
    }

    @Test func markersTellContentsApartWithinARunOnly() {
        let a = hidden(text("hello")).marker
        let again = hidden(text("hello")).marker
        #expect(a != nil)
        #expect(a == again)
        // Another run's key gives unrelated markers: over many contents,
        // at least one differs.
        let other = SymmetricKey(size: .bits256)
        let differs = (0..<20).contains { index in
            let item = makeItem(text("text \(index)"))
            return RowPresentation(item, hidingContents: true, markerKey: key).marker
                != RowPresentation(item, hidingContents: true, markerKey: other).marker
        }
        #expect(differs)
        #expect(RowPresentation(makeItem(text("hello"))).marker == nil)
    }
}

@MainActor @Suite struct PresentationModePanelTests {
    let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))

    func titles(_ model: PanelModel) -> [String] { model.rows.map(\.presentation.title) }

    @Test func turningItOnAndOffRebuildsTheRows() {
        store.add(text("hunter2"), sourceApp: "Notes", now: at(0))
        let model = PanelModel(store: store, now: { at(10) })
        model.open()
        #expect(titles(model) == ["hunter2"])
        model.hidesContents = true
        #expect(titles(model) == ["Text"])
        model.hidesContents = false
        #expect(titles(model) == ["hunter2"])
    }

    @Test func theFilterMatchesOnlyWhatRowsShow() {
        store.add(text("hunter2"), sourceApp: "Notes", now: at(0))
        store.add(text("other"), sourceApp: "Mail", now: at(1))
        let model = PanelModel(store: store, now: { at(10) })
        model.hidesContents = true
        model.open()
        model.query = "hunter"
        #expect(model.rows.isEmpty)
        model.query = "mail"
        #expect(model.rows.count == 1)
    }

    @Test func peekingShowsOnlyTheSelectedRowAndEndsOnOpen() {
        store.add(text("first secret thing"), sourceApp: "Notes", now: at(0))
        store.add(text("second thing"), sourceApp: "Notes", now: at(1))
        let model = PanelModel(store: store, now: { at(10) })
        model.open()
        model.peeking = true
        // Not in Presentation Mode: nothing to peek at.
        #expect(model.rows.allSatisfy { model.peek(for: $0) == nil })
        model.hidesContents = true
        model.peeking = true
        #expect(model.rows.map { model.peek(for: $0) } == ["second…", nil])
        model.open()
        #expect(model.rows.allSatisfy { model.peek(for: $0) == nil })
        #expect(model.selectionCanPeek)
        // Turning the mode off ends a peek too.
        model.peeking = true
        model.hidesContents = false
        #expect(!model.peeking)
        #expect(!model.selectionCanPeek)
        // Nor does a peek carry over into the mode turning on.
        model.peeking = true
        model.hidesContents = true
        #expect(!model.peeking)
    }

    @Test func aSecretOffersNoPeek() {
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(0))
        let model = PanelModel(store: store, now: { at(10) })
        model.hidesContents = true
        model.open()
        #expect(model.selectionIsSecret)
        #expect(!model.selectionCanPeek)
    }

    @Test func movingTheSelectionEndsAPeek() {
        store.add(text("first secret thing"), sourceApp: "Notes", now: at(0))
        store.add(text("second thing"), sourceApp: "Notes", now: at(1))
        let model = PanelModel(store: store, now: { at(10) })
        model.hidesContents = true
        model.open()
        model.peeking = true
        model.moveSelection(by: 1)
        #expect(!model.peeking)
        model.peeking = true
        model.select(model.rows[0].id)
        #expect(!model.peeking)
    }

    @Test func turningItOnWithAFilterSelectsTheFirstMatch() {
        store.add(text("beta mail"), sourceApp: "Notes", now: at(0))
        store.add(text("gamma"), sourceApp: "Mail", now: at(1))
        store.add(text("delta"), sourceApp: "Mail", now: at(2))
        let model = PanelModel(store: store, now: { at(10) })
        model.open()
        model.query = "mail"
        // delta, gamma, beta mail: select the one matching by its text.
        model.moveSelection(by: 2)
        #expect(model.selectedItem?.content == text("beta mail"))
        // Hidden, it no longer matches: the first match is selected, not
        // the row that slid into its place.
        model.hidesContents = true
        #expect(model.rows.count == 2)
        #expect(model.selectedItem?.content == text("delta"))
        // Without a filter every row stays, and so does the selection.
        model.query = ""
        model.moveSelection(by: 1)
        model.hidesContents = false
        #expect(model.selectedItem?.content == text("gamma"))
    }

    @Test func otherKindsShowOnlyThatTheyAreOther() {
        store.add(content(typed("com.example.private-thing", "data")), sourceApp: "Example", now: at(0))
        let model = PanelModel(store: store, now: { at(10) })
        model.hidesContents = true
        model.open()
        #expect(titles(model) == ["Other"])
        #expect(model.rows[0].presentation.tag == nil)
        #expect(!model.selectionCanPeek)
    }

    @Test func aRowCopiedAgainAsASecretEndsItsPeek() {
        store.add(text("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        let model = PanelModel(store: store, now: { at(10) })
        model.hidesContents = true
        model.open()
        model.peeking = true
        #expect(model.peek(for: model.rows[0]) == "hunter…")
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(20))
        #expect(titles(model) == ["Secret"])
        #expect(model.peek(for: model.rows[0]) == nil)
    }

    @Test func anImageOffersNoPeek() {
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 8, height: 4)))
        store.add(png, sourceApp: "Preview", now: at(0))
        let model = PanelModel(store: store, now: { at(10) })
        model.hidesContents = true
        model.open()
        #expect(model.rows[0].presentation.kind == .image)
        #expect(titles(model) == ["Image"])
        #expect(!model.selectionCanPeek)
    }
}

@Suite struct PeekGestureTests {
    /// Steps through the gesture, each step one call; times in seconds.
    final class Gesture {
        var value = PeekGesture()
        func option(_ at: TimeInterval) { value.modifiersChanged(optionAlone: true, none: false, at: at) }
        func release(_ at: TimeInterval) { value.modifiersChanged(optionAlone: false, none: true, at: at) }
        func command(_ at: TimeInterval) { value.modifiersChanged(optionAlone: false, none: false, at: at) }
        func chord(_ at: TimeInterval) { command(at) }
        func key() { value.keyPressed() }
        func peeks(_ at: TimeInterval) -> Bool { value.shouldPeek(at: at) }
    }

    @Test func tapThenHoldPeeksUntilLetGo() {
        let gesture = Gesture()
        gesture.option(0)
        gesture.release(0.1)
        gesture.option(0.2)
        // Not before the hold is up.
        #expect(!gesture.peeks(0.3))
        #expect(gesture.peeks(0.4))
        gesture.release(1)
        #expect(!gesture.peeks(1.2))
        // Not a third press straight after.
        gesture.option(1.1)
        #expect(!gesture.peeks(1.5))
    }

    @Test func typingWithOptionNeverPeeks() {
        let gesture = Gesture()
        // Hold Option as long as you like, then type @, twice.
        gesture.option(0)
        #expect(!gesture.peeks(2))
        gesture.key()
        gesture.release(2.1)
        gesture.option(2.2)
        gesture.key()
        gesture.release(2.3)
        #expect(!gesture.peeks(3))
    }

    @Test func aTapJustBeforeTypingDoesNotPeek() {
        let gesture = Gesture()
        // Touch Option, let go, then type @ at once: the key comes
        // within the hold, so the peek never shows.
        gesture.option(0)
        gesture.release(0.05)
        gesture.option(0.1)
        gesture.key()
        #expect(!gesture.peeks(0.3))
        gesture.release(0.35)
        #expect(!gesture.peeks(0.5))
    }

    @Test func slowTapsAndOtherModifiersDoNot() {
        let gesture = Gesture()
        // A press held too long is not a tap.
        gesture.option(0)
        gesture.release(1)
        gesture.option(1.1)
        #expect(!gesture.peeks(1.5))
        // A second press too late.
        gesture.release(1.2)
        gesture.option(2)
        #expect(!gesture.peeks(2.5))
        // Option released into Cmd is no tap.
        gesture.command(2.6)
        gesture.option(2.7)
        #expect(!gesture.peeks(3))
    }

    @Test func optionLeftAfterAChordIsNoTap() {
        let gesture = Gesture()
        // Type { with Option-Shift-8, let go of Shift, then of Option at
        // once; then Option for [ with a pause before the 8.
        gesture.option(0)
        gesture.chord(0.05)
        gesture.key()
        gesture.option(0.8)
        gesture.release(0.9)
        gesture.option(1.1)
        #expect(!gesture.peeks(1.3))
    }
}
