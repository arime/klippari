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

    /// Adds an item while the storage folder is read-only, so saving it
    /// fails and it is kept in memory only.
    func addKeptInMemory(_ content: ClipContent, to store: HistoryStore, now: Date) throws -> ClipItem {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        return store.add(content, sourceApp: nil, now: now)
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
        #expect(store.archiveSummary == ArchiveSummary(count: 3, archivedAt: at(20), clears: 2))
        #expect(store.restoreArchive() == RestoreResult(restored: 3, noRoom: 0))
        #expect(store.items.map(\.content) == [text("c"), text("b"), text("a")])
    }

    @Test func contentClearedAgainReplacesItsArchivedCopy() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.archiveAll(now: at(10))
        let newer = store.add(text("a"), sourceApp: nil, now: at(11))
        store.archiveAll(now: at(20))
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(20), clears: 2))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("a"), text("b")])
        #expect(store.items[0].id == newer.id)
        #expect(store.items[0].lastUsedAt == at(11))
    }

    @Test func clearingSavesAnItemThatIsOnlyInMemoryIntoTheArchive() throws {
        let store = makeStore()
        store.add(text("saved"), sourceApp: nil, now: at(1))
        // Saving fails while the storage folder is read-only, so the
        // next item is kept in memory only.
        let memory = try addKeptInMemory(text("memory"), to: store, now: at(2))
        #expect(itemsOnDisk() == 1)

        #expect(store.archiveAll(now: at(10)) == 2)
        #expect(store.items.isEmpty)
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(10)))
        #expect(store.restoreArchive().restored == 2)
        #expect(store.items.map(\.content) == [text("memory"), text("saved")])
        #expect(store.items[0].id == memory.id)
        #expect(makeStore().items.count == 2)
    }

    @Test func anItemOnlyInMemoryThatCannotBeArchivedStaysAndIsNotCounted() throws {
        let store = makeStore()
        store.add(text("saved"), sourceApp: nil, now: at(1))
        let memory = try addKeptInMemory(text("memory"), to: store, now: at(2))
        // Saving into the archive fails too: a read-only folder that
        // in it can be removed.is where the item would be built. Moving the
        // saved item's folder in still works.
        let fm = FileManager.default
        let building = store.archiveRoot.appendingPathComponent("19700101T024650Z")
            .appendingPathComponent(".tmp-" + memory.id.uuidString)
        try fm.createDirectory(at: building, withIntermediateDirectories: true)
        try Data().write(to: building.appendingPathComponent("in-the-way"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: building.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: building.path) }

        #expect(store.archiveAll(now: at(10)) == 1)
        #expect(store.items.map(\.id) == [memory.id])
        #expect(store.fullContent(for: memory.id) == text("memory"))
        #expect(store.archiveSummary?.count == 1)
    }

    @Test func restoreMergesByDateSkipsDuplicatesAndRemovesTheArchive() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(3))
        store.archiveAll(now: at(10))
        store.add(text("new"), sourceApp: nil, now: at(2))
        store.add(text("b"), sourceApp: nil, now: at(12)) // copied again since
        #expect(store.restoreArchive() == RestoreResult(restored: 1, noRoom: 0))
        #expect(store.items.map(\.content) == [text("b"), text("new"), text("a")])
        #expect(store.archiveSummary == nil)
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))

        // The restored item is back on disk for good.
        let reopened = makeStore()
        #expect(reopened.items.map(\.content) == [text("b"), text("new"), text("a")])
    }

    @Test func restoreBringsBackOnlyWhatFitsAndLeavesTheRest() {
        let store = makeStore(limit: 3)
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.add(text("b"), sourceApp: nil, now: at(2))
        store.add(text("c"), sourceApp: nil, now: at(3))
        store.archiveAll(now: at(10))
        store.add(text("new"), sourceApp: nil, now: at(11))
        // Room for two: the two used most recently come back.
        #expect(store.restoreArchive() == RestoreResult(restored: 2, noRoom: 1))
        #expect(store.items.map(\.content) == [text("new"), text("c"), text("b")])
        #expect(itemsOnDisk() == 3)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(10)))

        // With a larger history the rest comes back, and nothing was lost.
        store.limit = 4
        #expect(store.restoreArchive() == RestoreResult(restored: 1, noRoom: 0))
        #expect(store.items.map(\.content) == [text("new"), text("c"), text("b"), text("a")])
        #expect(store.archiveSummary == nil)
    }

    @Test func restoreIntoAFullHistoryChangesNothing() {
        let store = makeStore(limit: 2)
        store.add(text("a"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(10))
        let x = store.add(text("x"), sourceApp: nil, now: at(11))
        let y = store.add(text("y"), sourceApp: nil, now: at(12))
        var changes = 0
        store.onChange = { changes += 1 }
        #expect(store.restoreArchive() == RestoreResult(restored: 0, noRoom: 1))
        #expect(changes == 0)
        #expect(store.items.map(\.id) == [y.id, x.id])
        #expect(itemsOnDisk() == 2)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(10)))
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

        #expect(store.restoreArchive().restored == 1)
        #expect(store.items.map(\.content) == [text("b")])
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(10)))

        // With the way clear, the rest comes back and the archive goes.
        try FileManager.default.removeItem(at: blocker)
        #expect(store.restoreArchive().restored == 1)
        #expect(store.items.map(\.content) == [text("b"), text("a")])
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))
    }

    @Test func restoreWithoutAnArchiveDoesNothing() {
        let store = makeStore()
        store.add(text("a"), sourceApp: nil, now: at(1))
        #expect(store.restoreArchive() == RestoreResult(restored: 0, noRoom: 0))
        #expect(store.items.count == 1)
    }
}

@MainActor @Suite struct ClearedHistoryLifetimeTests {
    let root = temporaryRoot()

    @Test func deleteRemovesTheArchive() {
        let store = HistoryStore(storage: ItemStorage(root: root))
        store.add(text("a"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.deleteArchive()
        #expect(store.archiveSummary == nil)
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))
    }

    @Test func eachClearExpires24HoursAfterItWasMade() {
        let store = HistoryStore(storage: ItemStorage(root: root))
        let day = HistoryStore.archiveLifetime
        store.add(text("a"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(10))
        store.add(text("b"), sourceApp: nil, now: at(20))
        store.archiveAll(now: at(30))
        #expect(store.nextArchiveExpiry == at(10 + day))

        #expect(!store.expireArchive(now: at(10 + day - 1)))
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(30), clears: 2))
        // The first clear goes on its own day, not the last clear's.
        #expect(store.expireArchive(now: at(10 + day)))
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(30)))
        #expect(store.nextArchiveExpiry == at(30 + day))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("b")])
    }

    @Test func theNextExpiryFollowsClearsRestoresAndDeletes() {
        let store = HistoryStore(storage: ItemStorage(root: root))
        let day = HistoryStore.archiveLifetime
        #expect(store.nextArchiveExpiry == nil)
        store.add(text("a"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(10))
        store.add(text("b"), sourceApp: nil, now: at(20))
        store.archiveAll(now: at(30))
        #expect(store.nextArchiveExpiry == at(10 + day))
        // Room for one: 'b' comes back, emptying the second clear, and
        // the first is still due first.
        store.limit = 1
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("b")])
        #expect(store.nextArchiveExpiry == at(10 + day))
        store.limit = 2
        store.restoreArchive()
        #expect(store.nextArchiveExpiry == nil)
        store.archiveAll(now: at(40))
        #expect(store.nextArchiveExpiry == at(40 + day))
        store.deleteArchive()
        #expect(store.nextArchiveExpiry == nil)
    }

    @Test func aClearThatCannotBeDeletedIsTriedAgainAMinuteLater() throws {
        let store = HistoryStore(storage: ItemStorage(root: root))
        let day = HistoryStore.archiveLifetime
        store.add(text("a"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(10))
        #expect(store.nextArchiveCheck(now: at(20)) == at(10 + day))

        // A locked clear folder (chflags uchg): neither it nor the items
        // in it can be removed.
        let fm = FileManager.default
        let clear = try #require(try fm.contentsOfDirectory(atPath: store.archiveRoot.path).first)
        let clearPath = store.archiveRoot.appendingPathComponent(clear).path
        try fm.setAttributes([.immutable: true], ofItemAtPath: clearPath)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: clearPath) }
        let overdue = at(10 + day + 5)
        #expect(!store.expireArchive(now: overdue))
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(10)))
        #expect(store.nextArchiveCheck(now: overdue) == overdue.addingTimeInterval(HistoryStore.archiveRetryInterval))

        try fm.setAttributes([.immutable: false], ofItemAtPath: clearPath)
        #expect(store.expireArchive(now: overdue.addingTimeInterval(60)))
        #expect(store.nextArchiveCheck(now: overdue) == nil)
    }

    @Test func clearingEveryDayStillExpiresOlderClears() {
        let store = HistoryStore(storage: ItemStorage(root: root))
        let day = HistoryStore.archiveLifetime
        for (index, name) in ["a", "b", "c"].enumerated() {
            let time = Double(index) * day * 0.75
            store.add(text(name), sourceApp: nil, now: at(time))
            store.archiveAll(now: at(time + 1))
        }
        // Cleared at 0, 0.75 and 1.5 days: at 1.5 days only the first is
        // a day old.
        #expect(store.expireArchive(now: at(day * 1.5 + 1)))
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(day * 1.5 + 1), clears: 2))
        #expect(store.expireArchive(now: at(day * 2.5 + 1)))
        #expect(store.archiveSummary == nil)
        #expect(store.nextArchiveExpiry == nil)
        #expect(!FileManager.default.fileExists(atPath: store.archiveRoot.path))
    }

    @Test func aFlatArchiveFromAnEarlierBuildBecomesOneClear() throws {
        let archiveRoot = root.deletingLastPathComponent().appendingPathComponent("items-archive")
        let flat = ItemStorage(root: archiveRoot)
        try flat.save(makeItem(text("a"), lastUsed: 1))
        try flat.save(makeItem(text("b"), lastUsed: 2))
        try FileManager.default.setAttributes([.modificationDate: at(5)], ofItemAtPath: archiveRoot.path)

        let store = HistoryStore(storage: ItemStorage(root: root))
        #expect(store.archiveRoot.path == archiveRoot.path)
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(5)))
        let names = try FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)
        #expect(!names.contains { UUID(uuidString: $0) != nil })
        #expect(store.nextArchiveExpiry == at(5 + HistoryStore.archiveLifetime))
        store.add(text("c"), sourceApp: nil, now: at(6))
        store.archiveAll(now: at(7))
        #expect(store.archiveSummary == ArchiveSummary(count: 3, archivedAt: at(7), clears: 2))
        #expect(store.expireArchive(now: at(5 + HistoryStore.archiveLifetime)))
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(7)))
    }

    @Test func pastTheSizeLimitTheOldestClearsGo() {
        let store = HistoryStore(storage: ItemStorage(root: root))
        // Each clear takes a little over 10 000 bytes; two fit.
        store.archiveSizeLimit = 25_000
        for (index, name) in ["a", "b", "c"].enumerated() {
            store.add(text(String(repeating: name, count: 10_000)), sourceApp: nil, now: at(Double(index * 10)))
            store.archiveAll(now: at(Double(index * 10 + 1)))
        }
        #expect(store.archiveSummary == ArchiveSummary(count: 2, archivedAt: at(21), clears: 2))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [
            text(String(repeating: "c", count: 10_000)), text(String(repeating: "b", count: 10_000)),
        ])
    }

    @Test func theLastClearIsKeptEvenOverTheSizeLimit() {
        let store = HistoryStore(storage: ItemStorage(root: root))
        store.archiveSizeLimit = 100
        store.add(text(String(repeating: "a", count: 10_000)), sourceApp: nil, now: at(0))
        #expect(store.archiveAll(now: at(1)) == 1)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(1)))
    }
}
