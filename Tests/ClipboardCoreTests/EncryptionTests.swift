import Foundation
import Testing
import ClipboardCore

/// Writes an item the way versions before encryption did: plain files
/// and a plain JSON manifest. Returns its id.
@discardableResult
func writePlainItem(in root: URL, text string: String, withHash: Bool = true, lastUsed: TimeInterval = 0) throws -> UUID {
    let id = UUID()
    let directory = root.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(string.utf8).write(to: directory.appendingPathComponent("e0-t0.bin"))
    var manifest: [String: Any] = [
        "id": id.uuidString,
        "capturedAt": 0,
        "lastUsedAt": lastUsed,
        "sourceApp": "Notes",
        "entries": [[["type": TypeName.plainText, "file": "e0-t0.bin"]]],
    ]
    if withHash { manifest["contentHash"] = text(string).contentHash }
    try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
    return id
}

/// Every regular file under `root`.
func files(under root: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    return (enumerator?.allObjects as? [URL] ?? []).filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}

func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

@Suite struct ItemCipherTests {
    @Test func roundTrips() throws {
        let cipher = ItemCipher.ephemeral()
        let sealed = try cipher.seal(Data("hello".utf8), context: "a/b")
        #expect(ItemCipher.isSealed(sealed))
        #expect(try cipher.open(sealed, context: "a/b") == Data("hello".utf8))
    }

    @Test func refusesAnotherContextOrKey() throws {
        let cipher = ItemCipher.ephemeral()
        let sealed = try cipher.seal(Data("hello".utf8), context: "a/b")
        #expect(throws: (any Error).self) { try cipher.open(sealed, context: "a/c") }
        #expect(throws: (any Error).self) { try ItemCipher.ephemeral().open(sealed, context: "a/b") }
        #expect(throws: (any Error).self) { try cipher.open(Data("{}".utf8), context: "a/b") }
    }
}

@Suite struct EncryptedStorageTests {
    @Test func nothingIsWrittenInPlainForm() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root, cipher: testCipher)
        let png = content(
            typed(TypeName.plainText, "a very secret sentence"),
            TypedData(type: TypeName.png, data: makePNG(width: 80, height: 40))
        )
        try storage.save(makeItem(png, imageInfo: ImageInfo.inspect(png)))
        let written = files(under: root)
        #expect(written.count == 4) // two data files, thumbnail, manifest
        for file in written {
            let data = try Data(contentsOf: file)
            #expect(ItemCipher.isSealed(data), "\(file.lastPathComponent)")
            #expect(data.range(of: Data("secret sentence".utf8)) == nil)
            #expect(data.range(of: Data("Notes".utf8)) == nil)
        }
    }

    @Test func filesAre0600AndFoldersAre0700() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root, cipher: testCipher)
        var item = makeItem(text("x"))
        try storage.save(item)
        item.lastUsedAt = Date(timeIntervalSince1970: 5000)
        item.content = item.content.lightened
        try storage.updateManifest(item)
        #expect(permissions(root.appendingPathComponent(item.id.uuidString)) == 0o700)
        for file in files(under: root) {
            #expect(permissions(file) == 0o600, "\(file.lastPathComponent)")
        }
    }

    @Test func anotherKeyReadsNothingAndDropsTheItems() throws {
        let root = temporaryRoot()
        try ItemStorage(root: root, cipher: testCipher).save(makeItem(text("x")))
        let stranger = ItemStorage(root: root, cipher: .ephemeral())
        #expect(stranger.loadAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func plainItemsAreSealedAndTheirPlainFilesGo() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root, cipher: testCipher)
        let older = try writePlainItem(in: root, text: "older", lastUsed: 1)
        let newer = try writePlainItem(in: root, text: "newer", lastUsed: 2)
        #expect(storage.sealPlainItems() == 2)
        #expect(storage.sealPlainItems() == 0)
        #expect(storage.loadAll().map(\.id) == [newer, older])
        #expect(storage.loadContent(id: older) == text("older"))
        for file in files(under: root) {
            #expect(ItemCipher.isSealed(try Data(contentsOf: file)))
            #expect(permissions(file) == 0o600)
        }
    }

    @Test func aPlainItemThatFailsToSealIsKeptForTheNextLaunch() throws {
        let root = temporaryRoot()
        let id = try writePlainItem(in: root, text: "keep me")
        let directory = root.appendingPathComponent(id.uuidString)
        // A read-only item directory makes the swap fail, as a full disk would.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let storage = ItemStorage(root: root, cipher: testCipher)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(storage.sealPlainItems() == 0)
        #expect(storage.loadAll().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("e0-t0.bin").path))
        #expect(storage.sealPlainItems() == 1)
        #expect(storage.loadContent(id: id) == text("keep me"))
    }

    @Test func sealedItemFoldersBecome0700() throws {
        let root = temporaryRoot()
        let id = try writePlainItem(in: root, text: "x")
        let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        ItemStorage(root: root, cipher: testCipher).sealPlainItems()
        #expect(permissions(directory) == 0o700)
    }

    @Test func unreadablePlainItemsAreRemoved() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root, cipher: testCipher)
        let id = try writePlainItem(in: root, text: "x")
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString).appendingPathComponent("e0-t0.bin"))
        #expect(storage.sealPlainItems() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

@Suite struct StorageLocationTests {
    func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KlippariLocation-\(UUID().uuidString)")
    }

    @Test func archiveSitsNextToItems() {
        let folder = URL(fileURLWithPath: "/tmp/K")
        #expect(StorageLocation.archiveRoot(forItems: StorageLocation.itemsRoot(in: folder)).path
            == "/tmp/K/items-archive.noindex")
        #expect(StorageLocation.archiveRoot(forItems: folder.appendingPathComponent("items")).path
            == "/tmp/K/items-archive.noindex")
    }

    @Test func preparesAPrivateUnindexedUnbackedUpFolder() throws {
        let folder = makeFolder()
        try StorageLocation.prepare(folder)
        try StorageLocation.prepare(folder) // again, as on every launch
        #expect(permissions(folder) == 0o700)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".metadata_never_index").path))
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func movesTheOldFoldersToTheirNoindexNames() throws {
        let folder = makeFolder()
        let fm = FileManager.default
        let oldItems = folder.appendingPathComponent("items")
        let oldArchive = folder.appendingPathComponent("items-archive")
        let id = try writePlainItem(in: oldItems, text: "a")
        try writePlainItem(in: oldArchive, text: "b")
        try StorageLocation.prepare(folder)
        #expect(!fm.fileExists(atPath: oldItems.path))
        #expect(!fm.fileExists(atPath: oldArchive.path))
        let items = StorageLocation.itemsRoot(in: folder)
        #expect(fm.fileExists(atPath: items.appendingPathComponent(id.uuidString).path))
        #expect(try fm.contentsOfDirectory(atPath: StorageLocation.archiveRoot(forItems: items).path).count == 1)
    }

    @Test func anOldArchiveGetsAFullDayFromTheMove() throws {
        let folder = makeFolder()
        let oldArchive = folder.appendingPathComponent("items-archive")
        try writePlainItem(in: oldArchive, text: "b")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7 * 86400)], ofItemAtPath: oldArchive.path
        )
        try StorageLocation.prepare(folder)
        let archive = StorageLocation.archiveRoot(forItems: StorageLocation.itemsRoot(in: folder))
        let date = try #require(try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date)
        #expect(abs(date.timeIntervalSinceNow) < 60)
    }

    @Test func mergesOldItemsIntoAnExistingFolder() throws {
        let folder = makeFolder()
        let items = StorageLocation.itemsRoot(in: folder)
        try writePlainItem(in: items, text: "kept")
        let moved = try writePlainItem(in: folder.appendingPathComponent("items"), text: "moved")
        try StorageLocation.prepare(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("items").path))
        #expect(FileManager.default.fileExists(atPath: items.appendingPathComponent(moved.uuidString).path))
    }
}

@MainActor @Suite struct ArchiveLifetimeTests {
    let root = temporaryRoot()

    func makeStore() -> HistoryStore {
        HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
    }

    @Test func sealingAnOldArchiveKeepsItsDate() throws {
        let archive = StorageLocation.archiveRoot(forItems: root)
        try writePlainItem(in: archive, text: "old")
        try FileManager.default.setAttributes([.modificationDate: at(5)], ofItemAtPath: archive.path)
        let store = makeStore()
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(5)))
        for file in files(under: archive) {
            #expect(ItemCipher.isSealed(try Data(contentsOf: file)))
        }
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("old")])
    }

    @Test func sealingAClearKeepsItsDate() throws {
        let clear = StorageLocation.archiveRoot(forItems: root).appendingPathComponent("20261120T060413Z")
        try writePlainItem(in: clear, text: "cleared")
        let store = makeStore()
        let date = try Date("2026-11-20T06:04:13Z", strategy: .iso8601)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: date))
        for file in files(under: clear) {
            #expect(ItemCipher.isSealed(try Data(contentsOf: file)))
        }
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("cleared")])
    }
}
