import Foundation
import Testing
import ClipboardCore

@Suite struct RowPresentationTests {
    func row(_ content: ClipContent, sourceApp: String? = "Notes", imageInfo: ImageInfo? = nil) -> RowPresentation {
        RowPresentation(makeItem(content, sourceApp: sourceApp, imageInfo: imageInfo))
    }

    @Test func singleFile() {
        // What Finder puts on the pasteboard: a file URL plus the name as text.
        let r = row(content(
            typed(TypeName.fileURL, "file:///Users/me/report-final.pdf"),
            typed(TypeName.plainText, "report-final.pdf")
        ))
        #expect(r.kind == .file)
        #expect(r.title == "report-final.pdf")
        #expect(r.tag == "file")
    }

    @Test func severalFiles() {
        let r = row(ClipContent(entries: [
            PasteboardEntry(types: [typed(TypeName.fileURL, "file:///tmp/a.pdf")]),
            PasteboardEntry(types: [typed(TypeName.fileURL, "file:///tmp/b%20c.txt")]),
        ]))
        #expect(r.kind == .file)
        #expect(r.title == "2 files")
        #expect(r.tag == "file")
        #expect(r.matches("b c.txt"))
    }

    @Test func image() {
        let r = row(
            content(TypedData(type: TypeName.png, data: makePNG(width: 2, height: 2))),
            imageInfo: ImageInfo(width: 1280, height: 720, format: "PNG")
        )
        #expect(r.kind == .image)
        #expect(r.title == "Image")
        #expect(r.tag == "1280 × 720 · PNG")
    }

    @Test func imageAlsoOfferedAsItsFile() {
        // What clipaste writes after a screenshot: the PNG bytes plus a
        // file URL and path for the same PNG saved to disk. As held in
        // memory, so the image bytes are not loaded.
        let r = row(
            content(
                TypedData(type: TypeName.png, data: nil),
                typed(TypeName.fileURL, "file:///var/folders/xy/T/clipaste/shot-sha256-0640ee45.png"),
                TypedData(type: "com.apple.pboard.type.PNGf", data: nil),
                typed(TypeName.plainText, "/var/folders/xy/T/clipaste/shot-sha256-0640ee45.png"),
                typed("x.nspasteboard.ModifiedType", "42")
            ),
            imageInfo: ImageInfo(width: 2188, height: 1264, format: "PNG")
        )
        #expect(r.kind == .image)
        #expect(r.title == "Image")
        #expect(r.tag == "2188 × 1264 · PNG")
        #expect(r.matches("shot-sha256"))
    }

    @Test func imageFileCopiedInFinderStaysAFile() {
        // Finder adds the file's icon as image data, which is not PNG.
        let r = row(
            content(
                typed(TypeName.fileURL, "file:///Users/me/holiday.png"),
                typed(TypeName.plainText, "holiday.png"),
                TypedData(type: "com.apple.icns", data: nil),
                TypedData(type: TypeName.tiff, data: nil)
            ),
            imageInfo: ImageInfo(width: 512, height: 512, format: "TIFF")
        )
        #expect(r.kind == .file)
        #expect(r.title == "holiday.png")
    }

    @Test func fileWithPNGPreviewStaysAFile() {
        // The PNG is a picture of the file, not the file itself.
        let r = row(
            content(
                typed(TypeName.fileURL, "file:///Users/me/report.pdf"),
                TypedData(type: TypeName.png, data: nil)
            ),
            imageInfo: ImageInfo(width: 64, height: 64, format: "PNG")
        )
        #expect(r.kind == .file)
        #expect(r.title == "report.pdf")
    }

    @Test func styledText() {
        let rtf = row(content(typed(TypeName.plainText, "Meeting notes"), typed(TypeName.rtf, "{rtf}")))
        #expect(rtf.kind == .styledText)
        #expect(rtf.title == "Meeting notes")
        #expect(rtf.tag == "styled")
        let html = row(content(typed(TypeName.html, "<b>x</b>"), typed(TypeName.plainText, "x")))
        #expect(html.kind == .styledText)
    }

    @Test func link() {
        let r = row(text("https://developer.apple.com/documentation/appkit/nspasteboard"))
        #expect(r.kind == .link)
        #expect(r.title == "https://developer.apple.com/documentation/appkit/nspasteboard")
        #expect(r.tag == nil)
    }

    @Test func textContainingALinkIsNotALink() {
        #expect(row(text("see https://example.com for more")).kind == .text)
        #expect(row(text("https://example.com\nhttps://example.org")).kind == .text)
    }

    @Test func multilineText() {
        let lines = (1...14).map { "line \($0)" }.joined(separator: "\n")
        let r = row(text(lines))
        #expect(r.kind == .text)
        #expect(r.title == "line 1")
        #expect(r.tag == "14 lines")
    }

    @Test func titleIsFirstNonEmptyLineTrimmed() {
        let r = row(text("\n\n   func main() {\n}\n"))
        #expect(r.title == "func main() {")
        #expect(r.tag == "2 lines")
    }

    @Test func singleLineText() {
        let r = row(text("git rebase --onto main"))
        #expect(r.kind == .text)
        #expect(r.title == "git rebase --onto main")
        #expect(r.tag == nil)
    }

    @Test func whitespaceOnlyTextHasPlaceholderTitle() {
        let r = row(text("  \n "))
        #expect(r.kind == .text)
        #expect(r.title == "Empty text")
    }

    @Test func unknownType() {
        let r = row(content(typed("com.example.custom-thing", "x")))
        #expect(r.kind == .other)
        #expect(r.title == "com.example.custom-thing")
        #expect(r.tag == nil)
    }

    @Test func searchMatchesTextFileNameAndApp() {
        let note = row(text("Remember the Milk"), sourceApp: "Xcode")
        #expect(note.matches("XCO"))
        #expect(note.matches("milk"))
        #expect(note.matches(""))
        #expect(!note.matches("safari"))
        let file = row(content(typed(TypeName.fileURL, "file:///tmp/report-final.pdf")))
        #expect(file.matches("report"))
    }

    @Test func searchMatchesKindOfItem() {
        let image = row(
            content(TypedData(type: TypeName.png, data: nil)),
            sourceApp: "Preview", imageInfo: ImageInfo(width: 10, height: 10, format: "PNG")
        )
        #expect(image.matches("image"))
        #expect(image.matches("png"))
        #expect(!image.matches("link"))

        let link = row(text("https://example.com"))
        #expect(link.matches("link"))
        #expect(!link.matches("image"))

        #expect(row(content(typed(TypeName.fileURL, "file:///tmp/a.pdf"))).matches("file"))
        #expect(row(text("hello")).matches("text"))
        let styled = row(content(typed(TypeName.plainText, "x"), typed(TypeName.rtf, "{rtf}")))
        #expect(styled.matches("styled"))
        #expect(styled.matches("text"))
    }

    @Test func searchReachesBeyondTheFirstLine() {
        #expect(row(text("first\nsecond needle")).matches("needle"))
    }

    @Test func ageStrings() {
        let now = at(1_000_000)
        #expect(ageString(from: now.addingTimeInterval(-5), now: now) == "now")
        #expect(ageString(from: now.addingTimeInterval(-59), now: now) == "now")
        #expect(ageString(from: now.addingTimeInterval(-120), now: now) == "2 min")
        #expect(ageString(from: now.addingTimeInterval(-3600), now: now) == "1 h")
        #expect(ageString(from: now.addingTimeInterval(-3 * 86400), now: now) == "3 d")
        #expect(ageString(from: now.addingTimeInterval(60), now: now) == "now")
    }
}
