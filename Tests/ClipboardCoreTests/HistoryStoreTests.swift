import Foundation
import Testing
import ClipboardCore

func text(_ string: String) -> ClipContent {
    content(typed(TypeName.plainText, string))
}

func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 10_000 + seconds)
}

@MainActor @Suite struct HistoryStoreTests {
    let root = temporaryRoot()

    func makeStore(limit: Int = 50) -> HistoryStore {
        HistoryStore(storage: ItemStorage(root: root), limit: limit)
    }

    func itemsOnDisk() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).count
    }

    @Test func addInsertsAtTop() {
        let store = makeStore()
        store.add(text("a"), sourceApp: "Notes", now: at(1))
        store.add(text("b"), sourceApp: "Safari", now: at(2))
        #expect(store.items.map(\.content) == [text("b"), text("a")])
        #expect(store.items[0].sourceApp == "Safari")
        #expect(store.items[0].capturedAt == at(2))
        #expect(store.items[0].lastUsedAt == at(2))
    }

    @Test func addComputesImageInfo() {
        let store = makeStore()
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 8, height: 4)))
        let item = store.add(png, sourceApp: nil, now: at(1))
        #expect(item.imageInfo == ImageInfo(width: 8, height: 4, format: "PNG"))
        #expect(store.add(text("a"), sourceApp: nil, now: at(2)).imageInfo == nil)
    }

    @Test func duplicateMovesToTop() {
        let store = makeStore()
        let first = store.add(text("a"), sourceApp: "Notes", now: at(1))
        store.add(text("b"), sourceApp: "Safari", now: at(2))
        let again = store.add(text("a"), sourceApp: "Xcode", now: at(3))
        #expect(store.items.map(\.content) == [text("a"), text("b")])
        #expect(again.id == first.id)
        #expect(store.items[0].capturedAt == at(1))
        #expect(store.items[0].lastUsedAt == at(3))
        #expect(store.items[0].sourceApp == "Notes")
        #expect(itemsOnDisk() == 2)
    }

    @Test func capDropsOldest() {
        let store = makeStore(limit: 3)
        for (index, name) in ["a", "b", "c", "d"].enumerated() {
            store.add(text(name), sourceApp: nil, now: at(Double(index)))
        }
        #expect(store.items.map(\.content) == [text("d"), text("c"), text("b")])
        #expect(itemsOnDisk() == 3)
    }

    @Test func loweringLimitTrimsAtOnce() {
        let store = makeStore()
        for index in 0..<5 {
            store.add(text("item \(index)"), sourceApp: nil, now: at(Double(index)))
        }
        store.limit = 2
        #expect(store.items.map(\.content) == [text("item 4"), text("item 3")])
        #expect(itemsOnDisk() == 2)
    }

    @Test func limitIsAppliedWhenLoading() {
        let first = makeStore()
        for index in 0..<5 {
            first.add(text("item \(index)"), sourceApp: nil, now: at(Double(index)))
        }
        let second = makeStore(limit: 2)
        #expect(second.items.count == 2)
        #expect(itemsOnDisk() == 2)
    }

    @Test func markUsedMovesToTop() {
        let store = makeStore()
        let a = store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.markUsed(a.id, now: at(3))
        #expect(store.items.map(\.content) == [text("a"), text("b")])
        #expect(store.items[0].lastUsedAt == at(3))
        #expect(makeStore().items.map(\.content) == [text("a"), text("b")])
    }

    @Test func removeDeletesFromDisk() {
        let store = makeStore()
        let a = store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.remove(a.id)
        #expect(store.items.map(\.content) == [text("b")])
        #expect(itemsOnDisk() == 1)
    }

    @Test func clearEmptiesEverything() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.clear()
        #expect(store.items.isEmpty)
        #expect(itemsOnDisk() == 0)
    }

    @Test func persistsAcrossInstances() {
        let first = makeStore()
        first.add(text("a"), sourceApp: "Notes", now: at(1))
        first.add(text("b"), sourceApp: "Safari", now: at(2))
        #expect(makeStore().items == first.items)
    }

    @Test func onChangeFiresOnEachMutation() {
        let store = makeStore()
        var count = 0
        store.onChange = { count += 1 }
        let a = store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.markUsed(a.id, now: at(3))
        store.remove(a.id)
        store.limit = 10
        store.clear()
        #expect(count == 6)
    }

    // MARK: Archive

    @Test func archiveAllClearsIntoTheArchive() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        #expect(store.archiveSummary == nil)
        #expect(store.archiveAll(now: at(10)) == 2)
        #expect(store.items.isEmpty)
        #expect(itemsOnDisk() == 0)
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(10)))
    }

    @Test func archivingNothingKeepsThePreviousArchive() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(10))
        #expect(store.archiveAll(now: at(20)) == 0)
        #expect(store.archiveSummary?.count == 1)
    }

    @Test func clearingAgainAddsToTheArchive() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.archiveAll(now: at(10))
        store.add(text("c"), sourceApp: nil, now: at(11))
        #expect(store.archiveAll(now: at(20)) == 1)
        // Both clears are there, and the date is the last clear's.
        #expect(store.archiveSummary == ArchiveSummary(count: 3, archivedAt: at(20)))
        #expect(store.restoreArchive() == 3)
        #expect(store.items.map(\.content) == [text("c"), text("b"), text("a")])
    }

    @Test func contentClearedAgainReplacesItsArchivedCopy() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.archiveAll(now: at(10))
        let newer = store.add(text("a"), sourceApp: nil, now: at(11))
        store.archiveAll(now: at(20))
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(20)))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("a"), text("b")])
        #expect(store.items[0].id == newer.id)
        #expect(store.items[0].lastUsedAt == at(11))
    }

    @Test func clearingAnItemThatIsOnlyInMemoryLeavesNoEmptyArchive() throws {
        let store = makeStore()
        // Saving fails with a file where the storage folder was, so the
        // item is kept in memory only.
        try FileManager.default.removeItem(at: root)
        try Data().write(to: root)
        store.add(text("a"), sourceApp: nil, now: at(1))
        #expect(store.archiveAll(now: at(10)) == 1)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))
    }

    @Test func restoreMergesByDateSkipsDuplicatesAndRemovesTheArchive() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(3))
        store.archiveAll(now: at(10))
        store.add(text("new"), sourceApp: nil, now: at(2))
        store.add(text("b"), sourceApp: nil, now: at(12)) // copied again since
        #expect(store.restoreArchive() == 1)
        #expect(store.items.map(\.content) == [text("b"), text("new"), text("a")])
        #expect(store.archiveSummary == nil)
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))

        // The restored item is back on disk for good.
        let reopened = makeStore()
        #expect(reopened.items.map(\.content) == [text("b"), text("new"), text("a")])
    }

    @Test func restoreKeepsTheHistorySize() {
        let store = makeStore(limit: 2)
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.archiveAll(now: at(10))
        store.add(text("c"), sourceApp: nil, now: at(11))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("c"), text("b")])
        #expect(itemsOnDisk() == 2)
    }

    // MARK: Failures while clearing and restoring

    @Test func anItemThatCannotBeArchivedStaysInTheHistory() throws {
        let store = makeStore()
        let stuck = store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        // A directory that cannot be written to cannot be moved to
        // another folder.
        let directory = root.appendingPathComponent(stuck.id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        #expect(store.archiveAll(now: at(10)) == 1)
        #expect(store.items.map(\.id) == [stuck.id])
        #expect(store.fullContent(for: stuck.id) == text("a"))
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(10)))
    }

    @Test func clearingChangesNothingWhenTheArchiveCannotBeMade() throws {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        try Data().write(to: store.archiveRoot)
        var changes = 0
        store.onChange = { changes += 1 }
        #expect(store.archiveAll(now: at(10)) == 0)
        #expect(changes == 0)
        #expect(store.items.map(\.content) == [text("a")])
        #expect(itemsOnDisk() == 1)
    }

    @Test func anItemThatCannotBeRestoredStaysInTheArchive() throws {
        let store = makeStore()
        let stuck = store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.archiveAll(now: at(10))
        // Something is in the way of one item.
        let blocker = root.appendingPathComponent(stuck.id.uuidString)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        #expect(store.restoreArchive() == 1)
        #expect(store.items.map(\.content) == [text("b")])
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(10)))

        // With the way clear, the rest comes back and the archive goes.
        try FileManager.default.removeItem(at: blocker)
        #expect(store.restoreArchive() == 1)
        #expect(store.items.map(\.content) == [text("b"), text("a")])
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))
    }

    @Test func restoreWithoutAnArchiveDoesNothing() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        #expect(store.restoreArchive() == 0)
        #expect(store.items.count == 1)
    }
}
