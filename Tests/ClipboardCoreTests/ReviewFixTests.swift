import AppKit
import Foundation
import Testing
import ClipboardCore

/// Tests added in the fix pass after the whole-branch review.

func richContent() -> ClipContent {
    content(
        typed(TypeName.plainText, "hello"),
        typed(TypeName.rtf, "{\\rtf1 hello}"),
        TypedData(type: TypeName.png, data: makePNG(width: 8, height: 4))
    )
}

@Suite struct LightContentTests {
    @Test func lightenedKeepsOnlyTextAndFileURLs() {
        let rich = ClipContent(entries: [
            PasteboardEntry(types: [
                typed(TypeName.plainText, "hello"), typed(TypeName.rtf, "{rtf}"),
                typed(TypeName.fileURL, "file:///tmp/a.pdf"), typed("com.example.blob", "xyz"),
            ]),
        ])
        let light = rich.lightened
        #expect(light.plainString == "hello")
        #expect(light.fileURLs.count == 1)
        #expect(light.data(for: TypeName.rtf) == nil)
        #expect(light.data(for: "com.example.blob") == nil)
        #expect(light.hasType(TypeName.rtf))
        #expect(light.hasType("com.example.blob"))
        #expect(!light.hasType(TypeName.png))
        #expect(!light.isComplete)
        #expect(rich.isComplete)
    }

    @Test func styledRowDoesNotNeedStyleData() {
        let item = makeItem(content(typed(TypeName.plainText, "Notes"), typed(TypeName.rtf, "{rtf}")).lightened)
        let row = RowPresentation(item)
        #expect(row.kind == .styledText)
        #expect(row.tag == "styled")
    }

    @Test func itemRemembersHashOfFullContent() {
        let rich = richContent()
        let item = ClipItem(
            id: UUID(), capturedAt: at(0), lastUsedAt: at(0), sourceApp: nil,
            content: rich.lightened, imageInfo: nil, contentHash: rich.contentHash
        )
        #expect(item.contentHash == rich.contentHash)
        #expect(makeItem(rich).contentHash == rich.contentHash)
    }
}

@Suite struct LightStorageTests {
    @Test func loadAllKeepsOnlyTextInMemory() throws {
        let storage = ItemStorage(root: temporaryRoot())
        let item = makeItem(richContent(), imageInfo: ImageInfo.inspect(richContent()))
        try storage.save(item)
        let loaded = try #require(storage.loadAll().first)
        #expect(loaded.content == richContent().lightened)
        #expect(loaded.contentHash == richContent().contentHash)
        #expect(loaded.imageInfo == item.imageInfo)
    }

    @Test func loadContentReturnsEverything() throws {
        let storage = ItemStorage(root: temporaryRoot())
        let item = makeItem(richContent())
        try storage.save(item)
        #expect(storage.loadContent(id: item.id) == richContent())
        #expect(storage.loadContent(id: UUID()) == nil)
    }

    @Test func saveRefusesIncompleteContent() {
        let storage = ItemStorage(root: temporaryRoot())
        #expect(throws: (any Error).self) {
            try storage.save(makeItem(richContent().lightened))
        }
        #expect(storage.loadAll().isEmpty)
    }

    @Test func updateManifestLeavesDataFilesAlone() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root)
        var item = makeItem(richContent())
        try storage.save(item)
        let dataFile = root.appendingPathComponent(item.id.uuidString).appendingPathComponent("e0-t2.bin")
        let before = try FileManager.default.attributesOfItem(atPath: dataFile.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)

        item.lastUsedAt = Date(timeIntervalSince1970: 9000)
        item.content = item.content.lightened
        try storage.updateManifest(item)

        let after = try FileManager.default.attributesOfItem(atPath: dataFile.path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(storage.loadAll().first?.lastUsedAt == Date(timeIntervalSince1970: 9000))
        #expect(storage.loadContent(id: item.id) == richContent())
    }

    @Test func loadsManifestWrittenBeforeHashesWereStored() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root)
        let item = makeItem(richContent())
        try storage.save(item)
        let manifestURL = root.appendingPathComponent(item.id.uuidString).appendingPathComponent("manifest.json")
        var json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        json.removeValue(forKey: "contentHash")
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        #expect(storage.loadAll().first?.contentHash == richContent().contentHash)
    }
}

@MainActor @Suite struct LightStoreTests {
    let root = temporaryRoot()

    func makeStore() -> HistoryStore {
        HistoryStore(storage: ItemStorage(root: root))
    }

    @Test func itemsHoldOnlyTextInMemory() {
        let store = makeStore()
        let item = store.add(richContent(), sourceApp: nil, now: at(1))
        #expect(item.content == richContent().lightened)
        #expect(store.items[0].content.data(for: TypeName.png) == nil)
        #expect(store.items[0].imageInfo == ImageInfo(width: 8, height: 4, format: "PNG"))
        #expect(store.fullContent(for: item.id) == richContent())
    }

    @Test func richDuplicateIsStillDetected() {
        let store = makeStore()
        let first = store.add(richContent(), sourceApp: nil, now: at(1))
        store.add(text("other"), sourceApp: nil, now: at(2))
        let again = store.add(richContent(), sourceApp: nil, now: at(3))
        #expect(again.id == first.id)
        #expect(store.items.count == 2)
        #expect(store.fullContent(for: first.id) == richContent())
    }

    @Test func markUsedKeepsFullContentOnDisk() {
        let store = makeStore()
        let item = store.add(richContent(), sourceApp: nil, now: at(1))
        store.add(text("other"), sourceApp: nil, now: at(2))
        store.markUsed(item.id, now: at(3))
        #expect(store.fullContent(for: item.id) == richContent())
        #expect(makeStore().items.first?.id == item.id)
    }
}

@MainActor @Suite struct LightMonitorTests {
    @Test func pasteWritesFullContentFromDisk() {
        let pasteboard = FakePasteboard()
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot()))
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store, sourceApp: { nil }, now: { at(0) })
        pasteboard.copy(richContent())
        monitor.tick()
        monitor.paste(store.items[0], plainText: false)
        #expect(pasteboard.written == [richContent()])
    }
}

@MainActor @Suite struct SystemPasteboardTests {
    func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ClipboardCoreTests-\(UUID().uuidString)"))
    }

    func put(_ pairs: [(String, Data)], on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in pairs {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        pasteboard.writeObjects([item])
    }

    @Test func readsEveryType() {
        let raw = makePasteboard()
        defer { raw.releaseGlobally() }
        put([(TypeName.plainText, Data("hi".utf8)), (TypeName.rtf, Data("{rtf}".utf8))], on: raw)
        let read = SystemPasteboard(pasteboard: raw).read()
        #expect(read.plainString == "hi")
        #expect(read.data(for: TypeName.rtf) == Data("{rtf}".utf8))
    }

    @Test func doesNotReadDataOfConcealedContent() {
        let raw = makePasteboard()
        defer { raw.releaseGlobally() }
        put([
            (TypeName.plainText, Data("hunter2".utf8)),
            ("org.nspasteboard.ConcealedType", Data()),
        ], on: raw)
        let read = SystemPasteboard(pasteboard: raw).read()
        #expect(read.plainString == nil)
        #expect(read.hasType("org.nspasteboard.ConcealedType"))
        #expect(CaptureFilter.accept(read) == nil)
    }

    @Test func stopsReadingOnceOverTheSizeCap() {
        let raw = makePasteboard()
        defer { raw.releaseGlobally() }
        put([
            (TypeName.tiff, Data(count: CaptureFilter.maxBytes + 1)),
            (TypeName.png, Data(count: 1024)),
        ], on: raw)
        let read = SystemPasteboard(pasteboard: raw).read()
        #expect(read.data(for: TypeName.png) == nil)
        #expect(CaptureFilter.accept(read) == nil)
    }

    @Test func writeThenReadRoundTrips() {
        let raw = makePasteboard()
        defer { raw.releaseGlobally() }
        let pasteboard = SystemPasteboard(pasteboard: raw)
        let before = pasteboard.changeCount
        let after = pasteboard.write(richContent())
        #expect(after != before)
        // The system may add representations of its own (UTF-16 text), so
        // compare what was written type by type.
        let read = pasteboard.read()
        for typed in richContent().entries[0].types {
            #expect(read.data(for: typed.type) == typed.data)
        }
    }
}

@Suite struct ShortcutPolicyTests {
    // Virtual key codes: C 8, V 9, X 7, Q 12, W 13, A 0, Z 6, K 40.
    @Test(arguments: [8, 9, 7, 12, 13, 0, 6] as [UInt32])
    func plainCommandEditingAndWindowKeysAreReserved(keyCode: UInt32) {
        #expect(ShortcutPolicy.isReserved(keyCode: keyCode, command: true, control: false, option: false, shift: false))
    }

    @Test func defaultShortcutIsAllowed() {
        #expect(!ShortcutPolicy.isReserved(keyCode: 9, command: true, control: false, option: false, shift: true))
    }

    @Test func otherCombinationsAreAllowed() {
        #expect(!ShortcutPolicy.isReserved(keyCode: 40, command: true, control: false, option: false, shift: false))
        #expect(!ShortcutPolicy.isReserved(keyCode: 9, command: false, control: true, option: true, shift: false))
        #expect(!ShortcutPolicy.isReserved(keyCode: 9, command: true, control: false, option: true, shift: false))
    }

    @Test func redoIsReserved() {
        #expect(ShortcutPolicy.isReserved(keyCode: 6, command: true, control: false, option: false, shift: true))
    }
}
