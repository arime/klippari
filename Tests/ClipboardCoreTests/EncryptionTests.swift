import CryptoKit
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

    @Test func anotherKeyReadsNothingAndLeavesTheItems() throws {
        let root = temporaryRoot()
        let owner = ItemStorage(root: root, cipher: testCipher)
        try owner.save(makeItem(text("x")))
        let stranger = ItemStorage(root: root, cipher: .ephemeral())
        #expect(stranger.loadAll().isEmpty)
        // Nothing was deleted: with its own key back, the item loads.
        #expect(owner.loadAll().map(\.content) == [text("x")])
    }

    @Test func anItemWithOurManifestButMissingDataIsRemoved() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root, cipher: testCipher)
        let item = makeItem(text("x"))
        try storage.save(item)
        let directory = root.appendingPathComponent(item.id.uuidString)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("e0-t0.bin"))
        #expect(storage.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor @Test func clearingLeavesItemsSealedWithAnotherKeyWhereTheyAre() throws {
        let root = temporaryRoot()
        let foreign = makeItem(text("theirs"))
        try ItemStorage(root: root, cipher: .ephemeral()).save(foreign)
        let store = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        #expect(store.items.isEmpty)
        store.add(text("ours"), sourceApp: nil, now: at(1))
        #expect(store.archiveAll(now: at(2)) == 1)
        #expect(store.archiveSummary?.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [foreign.id.uuidString])
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
        // A read-only history folder makes the sealed copy impossible to
        // write, as a full disk would. ItemStorage makes its folder
        // writable, so the folder is made read-only again after it.
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

    @Test func aManifestInAnUnknownFormIsLeftAlone() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root, cipher: testCipher)
        var kept: [URL] = []
        // A later format, and a sealed manifest whose first bytes are damaged.
        for manifest in [Data("KLP2 something newer".utf8), Data([0x00, 0x4C, 0x50, 0x31, 0x9A, 0x07])] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try manifest.write(to: directory.appendingPathComponent("manifest.json"))
            kept.append(directory)
        }
        #expect(storage.sealPlainItems() == 0)
        #expect(storage.loadAll().isEmpty)
        for directory in kept {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        }
    }
}

@Suite struct MissingKeyTests {
    struct Unexpected: Error {}

    @Test func theStoredKeyIsUsed() throws {
        let root = temporaryRoot()
        try ItemStorage(root: root, cipher: testCipher).save(makeItem(text("x")))
        let stored = SymmetricKey(size: .bits256)
        let key = try ItemCipher.key(stored: stored, sealedHistoryIn: [root]) { throw Unexpected() }
        #expect(key == stored)
    }

    @Test func aNewKeyIsMadeWhenNothingIsSealed() throws {
        let root = temporaryRoot()
        let archive = StorageLocation.archiveRoot(forItems: root)
        // History from before encryption does not need the key.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writePlainItem(in: root, text: "old")
        let fresh = SymmetricKey(size: .bits256)
        #expect(try ItemCipher.key(stored: nil, sealedHistoryIn: [root, archive]) { fresh } == fresh)
    }

    @Test func noNewKeyWhileSealedItemsExist() throws {
        let root = temporaryRoot()
        try ItemStorage(root: root, cipher: testCipher).save(makeItem(text("x")))
        var made = false
        #expect(throws: ItemCipher.MissingKey.self) {
            try ItemCipher.key(stored: nil, sealedHistoryIn: [root]) {
                made = true
                return SymmetricKey(size: .bits256)
            }
        }
        #expect(!made)
    }

    @MainActor @Test func noNewKeyWhileTheArchiveHoldsSealedItems() throws {
        let root = temporaryRoot()
        let store = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        store.add(text("x"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(2))
        let archive = store.archiveRoot
        #expect(!ItemStorage.holdsSealedItems(root))
        #expect(ItemStorage.holdsSealedItems(archive))
        #expect(throws: ItemCipher.MissingKey.self) {
            try ItemCipher.key(stored: nil, sealedHistoryIn: [root, archive]) { SymmetricKey(size: .bits256) }
        }
    }
}

@MainActor @Suite struct AdoptedHistoryTests {
    @MainActor @Test func resetDeletesOnlyWhatTheLostKeySealed() throws {
        let root = temporaryRoot()
        let archive = StorageLocation.archiveRoot(forItems: root)
        let clear = archive.appendingPathComponent("20261120T060413Z")
        let lost = ItemCipher.ephemeral()
        let sealed = makeItem(text("sealed"))
        try ItemStorage(root: root, cipher: lost).save(sealed)
        let sealedCleared = makeItem(text("sealed, cleared"))
        try ItemStorage(root: clear, cipher: lost).save(sealedCleared)
        let plain = try writePlainItem(in: root, text: "plain")
        try writePlainItem(in: clear, text: "plain, cleared")

        for folder in [root, archive] {
            try ItemStorage.removeSealedItems(folder)
        }
        #expect(!ItemStorage.holdsSealedItems(root))
        #expect(!ItemStorage.holdsSealedItems(archive))
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(sealed.id.uuidString).path))
        #expect(!fm.fileExists(atPath: clear.appendingPathComponent(sealedCleared.id.uuidString).path))

        // The new key is allowed now, and the plain items open with it.
        let key = try ItemCipher.key(stored: nil, sealedHistoryIn: [root, archive]) { SymmetricKey(size: .bits256) }
        let store = HistoryStore(storage: ItemStorage(root: root, cipher: ItemCipher(key: key)))
        #expect(store.items.map(\.id) == [plain])
        store.restoreArchive()
        #expect(store.items.count == 2)
        #expect(store.items.contains { $0.content == text("plain, cleared") })
    }

    @Test func aSavedStoreTakesOverAnUnsavedOnesItems() throws {
        // What a run without the key holds: a throwaway folder and key.
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: .ephemeral()))
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 80, height: 40)))
        unsaved.add(text("first"), sourceApp: "Notes", now: at(1))
        let image = unsaved.add(png, sourceApp: "Preview", now: at(2))

        let root = temporaryRoot()
        let saved = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        saved.adopt(unsaved)
        #expect(saved.items.map(\.id) == unsaved.items.map(\.id))
        #expect(saved.fullContent(for: image.id) == png)
        #expect(saved.thumbnail(for: image.id) != nil)

        // Saved for good under the new key.
        let reopened = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        #expect(reopened.items.map(\.content) == [png.lightened, text("first")])
        #expect(reopened.fullContent(for: image.id) == png)
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

    @Test func mergesAnOldClearIntoOneOfTheSameName() throws {
        let folder = makeFolder()
        let fm = FileManager.default
        let archive = StorageLocation.archiveRoot(forItems: StorageLocation.itemsRoot(in: folder))
        let name = "20261120T060413Z"
        let kept = try writePlainItem(in: archive.appendingPathComponent(name), text: "kept")
        let oldArchive = folder.appendingPathComponent("items-archive")
        let moved = try writePlainItem(in: oldArchive.appendingPathComponent(name), text: "moved")
        try StorageLocation.prepare(folder)
        #expect(!fm.fileExists(atPath: oldArchive.path))
        let clear = archive.appendingPathComponent(name)
        #expect(fm.fileExists(atPath: clear.appendingPathComponent(kept.uuidString).path))
        #expect(fm.fileExists(atPath: clear.appendingPathComponent(moved.uuidString).path))
    }

    @Test func anItemInBothFoldersKeepsTheCurrentCopy() throws {
        let folder = makeFolder()
        let fm = FileManager.default
        let items = StorageLocation.itemsRoot(in: folder)
        let id = try writePlainItem(in: items, text: "current")
        let old = folder.appendingPathComponent("items").appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("e0-t0.bin"))
        try StorageLocation.prepare(folder)
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("items").path))
        let data = try Data(contentsOf: items.appendingPathComponent(id.uuidString).appendingPathComponent("e0-t0.bin"))
        #expect(data == Data("current".utf8))
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
