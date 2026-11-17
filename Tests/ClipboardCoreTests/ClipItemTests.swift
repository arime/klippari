import Foundation
import Testing
import ClipboardCore

func typed(_ type: String, _ string: String) -> TypedData {
    TypedData(type: type, data: Data(string.utf8))
}

func content(_ types: TypedData...) -> ClipContent {
    ClipContent(entries: [PasteboardEntry(types: types)])
}

@Suite struct ClipItemTests {
    @Test func hashIsStableAndOrderSensitive() {
        let a = content(typed(TypeName.plainText, "hi"), typed(TypeName.rtf, "{rtf}"))
        let same = content(typed(TypeName.plainText, "hi"), typed(TypeName.rtf, "{rtf}"))
        let swapped = content(typed(TypeName.rtf, "{rtf}"), typed(TypeName.plainText, "hi"))
        #expect(a.contentHash == same.contentHash)
        #expect(a.contentHash != swapped.contentHash)
        #expect(a.contentHash.count == 64)
    }

    @Test func hashDistinguishesTypeBoundaries() {
        let a = content(typed("ab", "c"))
        let b = content(typed("a", "bc"))
        #expect(a.contentHash != b.contentHash)
    }

    @Test func plainTextOnlyStripsStyles() {
        let styled = content(typed(TypeName.plainText, "hi"), typed(TypeName.rtf, "{rtf}"))
        let plain = styled.plainTextOnly
        #expect(plain == content(typed(TypeName.plainText, "hi")))
        #expect(content(typed(TypeName.png, "png")).plainTextOnly == nil)
    }

    @Test func totalBytesSumsAllTypes() {
        let c = ClipContent(entries: [
            PasteboardEntry(types: [typed("a", "12"), typed("b", "345")]),
            PasteboardEntry(types: [typed("a", "6")]),
        ])
        #expect(c.totalBytes == 6)
    }

    @Test func fileURLsComeFromEveryEntry() {
        let c = ClipContent(entries: [
            PasteboardEntry(types: [typed(TypeName.fileURL, "file:///tmp/a.pdf")]),
            PasteboardEntry(types: [typed(TypeName.fileURL, "file:///tmp/b.txt")]),
        ])
        #expect(c.fileURLs.map(\.lastPathComponent) == ["a.pdf", "b.txt"])
    }

    @Test func plainStringDecodesFirstPlainText() {
        #expect(content(typed(TypeName.plainText, "héllo")).plainString == "héllo")
        #expect(content(typed(TypeName.png, "x")).plainString == nil)
    }
}
