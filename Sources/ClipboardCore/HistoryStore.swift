import Foundation
import os

/// The cleared history, which can be restored.
public struct ArchiveSummary: Equatable, Sendable {
    public var count: Int
    /// When the last clear was made.
    public var archivedAt: Date
    /// How many clears the items come from.
    public var clears: Int

    public init(count: Int, archivedAt: Date, clears: Int = 1) {
        self.count = count
        self.archivedAt = archivedAt
        self.clears = clears
    }
}

/// What a restore did.
public struct RestoreResult: Equatable, Sendable {
    /// How many items came back.
    public var restored: Int
    /// How many stayed in the archive because the history was full.
    public var noRoom: Int

    public init(restored: Int, noRoom: Int) {
        self.restored = restored
        self.noRoom = noRoom
    }
}

/// The ordered history, newest first, mirrored to disk. Items in memory
/// carry lightened content (text and file URLs only); images and other
/// large data stay on disk until an item is pasted.
@MainActor public final class HistoryStore {
    /// How long each clear can be restored after it was made.
    public static let archiveLifetime: TimeInterval = 24 * 60 * 60
    /// The most the cleared history may take on disk, in bytes. Past
    /// it the oldest clears are deleted, though never the one just made.
    public var archiveSizeLimit: Int64 = 1_000_000_000

    private let storage: ItemStorage
    /// Where clearing the history moves it, so clearing can be
    /// undone: next to the storage, as '<storage folder>-archive', with
    /// a folder for each clear.
    public let archiveRoot: URL
    private var archive: ClearedHistory { ClearedHistory(root: archiveRoot) }
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "store")

    public private(set) var items: [ClipItem]

    /// Maximum number of items kept. Lowering it drops the oldest at once.
    public var limit: Int {
        didSet {
            trim()
            onChange?()
        }
    }

    /// Called after every mutation.
    public var onChange: (() -> Void)?

    public init(storage: ItemStorage, limit: Int = 50) {
        self.storage = storage
        archiveRoot = storage.root.deletingLastPathComponent()
            .appendingPathComponent(storage.root.lastPathComponent + "-archive")
        self.limit = limit
        self.items = storage.loadAll()
        trim()
        archive.adoptFlatLayout()
    }

    /// Records a copy. Content identical to an existing item moves that
    /// item to the top instead of adding a duplicate.
    @discardableResult
    public func add(_ content: ClipContent, sourceApp: String?, now: Date) -> ClipItem {
        let hash = content.contentHash
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            return touch(index, now: now)
        }

        var item = ClipItem(
            id: UUID(), capturedAt: now, lastUsedAt: now, sourceApp: sourceApp,
            content: content, imageInfo: ImageInfo.inspect(content), contentHash: hash
        )
        do {
            try storage.save(item)
            item.content = content.lightened
        } catch {
            // Keep the full content in memory, so the item can still be
            // pasted; it just will not survive a restart.
            Self.logger.error("Could not save item: \(error.localizedDescription, privacy: .public)")
        }
        items.insert(item, at: 0)
        trim()
        onChange?()
        return item
    }

    public func markUsed(_ id: UUID, now: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        touch(index, now: now)
    }

    /// The item's complete content for pasting. Falls back to what is in
    /// memory if the disk copy cannot be read.
    public func fullContent(for id: UUID) -> ClipContent? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if item.content.isComplete { return item.content }
        return storage.loadContent(id: id) ?? item.content
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        storage.delete(id: id)
        onChange?()
    }

    /// Clears the history by moving it to the archive, as a clear of its
    /// own beside those made before: an archived copy of something
    /// cleared again now gives way to the newer one. Returns how many
    /// items were cleared. An item kept only in memory, because saving
    /// it failed, is saved into the archive. An item that could not be
    /// moved or saved stays in the history and is not counted; 0 means
    /// nothing changed. If the archive has grown past
    /// `archiveSizeLimit`, the oldest clears are deleted.
    @discardableResult
    public func archiveAll(now: Date) -> Int {
        guard !items.isEmpty else { return 0 }
        let archive = archive
        let earlier = archive.items()
        let clear = archive.storage(for: now)
        var (moved, left) = storage.archiveAll(to: clear)
        // An item whose save failed is only in memory, with its full
        // content: save it into the archive instead. If that fails too,
        // it stays in the history.
        for item in items where !moved.contains(item.id) && !left.contains(item.id) {
            do {
                try clear.save(item)
                moved.insert(item.id)
            } catch {
                left.insert(item.id)
            }
        }
        if !left.isEmpty {
            Self.logger.error("Could not archive \(left.count) items")
        }

        let cleared = Set(items.filter { moved.contains($0.id) }.map(\.contentHash))
        for old in earlier where cleared.contains(old.item.contentHash) {
            // The same item moved into the same folder has replaced itself.
            if old.clear.storage.root.path == clear.root.path && moved.contains(old.item.id) { continue }
            old.clear.storage.delete(id: old.item.id)
        }
        archive.removeEmpty()
        archive.trim(toBytes: archiveSizeLimit, keeping: clear)

        // What was archived is gone from the history, so the list never
        // shows an item whose files have moved, and the count is only
        // of items that can be restored.
        let before = items.count
        items.removeAll { moved.contains($0.id) }
        guard items.count != before else { return 0 }
        onChange?()
        return before - items.count
    }

    /// The archived history, if there is one.
    public var archiveSummary: ArchiveSummary? {
        archive.summary
    }

    /// When the oldest clear is due to be deleted; nil when nothing is
    /// cleared.
    public var nextArchiveExpiry: Date? {
        archive.nextExpiry(lifetime: Self.archiveLifetime)
    }

    /// The shortest wait before checking the cleared history again.
    public static let archiveRetryInterval: TimeInterval = 60

    /// When to next check the cleared history: when the oldest clear is
    /// due, but never sooner than `archiveRetryInterval` from `now`. A
    /// clear that is overdue because it could not be deleted is then
    /// tried again once a minute, rather than over and over at once.
    /// Nil when nothing is cleared.
    public func nextArchiveCheck(now: Date) -> Date? {
        nextArchiveExpiry.map { max($0, now.addingTimeInterval(Self.archiveRetryInterval)) }
    }

    /// Deletes the archive for good.
    public func deleteArchive() {
        try? FileManager.default.removeItem(at: archiveRoot)
    }

    /// Deletes each clear `archiveLifetime` after it was made. Returns
    /// whether any was deleted.
    @discardableResult
    public func expireArchive(now: Date) -> Bool {
        archive.expire(now: now, lifetime: Self.archiveLifetime)
    }

    /// Puts back as many archived items as the history has room for,
    /// newest first by when each was last used, merged with what was
    /// copied since. The rest stay in the archive, so a restore never
    /// deletes an item or pushes one out of the history. The only thing
    /// it removes from the archive besides what came back is a copy of
    /// something already in the history. An item that could not be
    /// moved stays there too, in its clear, to be restored later.
    @discardableResult
    public func restoreArchive() -> RestoreResult {
        let archive = archive
        var seen = Set(items.map(\.contentHash))
        var waiting: [(item: ClipItem, clear: ClearedHistory.Clear)] = []
        // Newest first, so a second copy of the same content is the older.
        for old in archive.items() {
            if seen.insert(old.item.contentHash).inserted {
                waiting.append(old)
            } else {
                old.clear.storage.delete(id: old.item.id)
            }
        }

        let room = max(limit - items.count, 0)
        var restored = 0
        var tried = 0
        for (item, clear) in waiting where restored < room {
            tried += 1
            do {
                try clear.storage.move(id: item.id, to: storage)
                items.append(item)
                restored += 1
            } catch {
                Self.logger.error("Could not restore item: \(error.localizedDescription, privacy: .public)")
            }
        }
        archive.removeEmpty()
        if restored > 0 {
            items.sort { $0.lastUsedAt > $1.lastUsedAt }
            onChange?()
        }
        return RestoreResult(restored: restored, noRoom: waiting.count - tried)
    }

    public func clear() {
        items.removeAll()
        storage.deleteAll()
        onChange?()
    }

    /// Moves an item to the top. Only its manifest is rewritten; the data
    /// files, which can be large, are left alone.
    @discardableResult
    private func touch(_ index: Int, now: Date) -> ClipItem {
        var item = items.remove(at: index)
        item.lastUsedAt = now
        items.insert(item, at: 0)
        do {
            try storage.updateManifest(item)
        } catch {
            Self.logger.error("Could not update item: \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
        return item
    }

    private func trim() {
        let keep = max(limit, 0)
        while items.count > keep {
            storage.delete(id: items.removeLast().id)
        }
    }
}
