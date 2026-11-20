import Foundation
import os

/// The cleared history, which can be restored.
public struct ArchiveSummary: Equatable, Sendable {
    public var count: Int
    public var archivedAt: Date

    public init(count: Int, archivedAt: Date) {
        self.count = count
        self.archivedAt = archivedAt
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
    /// How long the cleared history can be restored after the last clear.
    public static let archiveLifetime: TimeInterval = 24 * 60 * 60

    private let storage: ItemStorage
    /// Where clearing the history moves it, so clearing can be
    /// undone: next to the storage, as '<storage folder>-archive'.
    public let archiveRoot: URL
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

    /// Clears the history by moving it to the archive, adding to what was
    /// cleared before: an archived copy of something cleared again now
    /// gives way to the newer one. The archive's date restarts. Returns
    /// how many items were cleared. An item whose files could not be
    /// moved stays in the history; 0 means nothing changed.
    @discardableResult
    public func archiveAll(now: Date) -> Int {
        guard !items.isEmpty else { return 0 }
        let archive = ItemStorage(root: archiveRoot)
        let earlier = archive.loadAll()
        let (moved, left) = storage.archiveAll(to: archive, at: now)
        if !left.isEmpty {
            Self.logger.error("Could not archive \(left.count) items")
        }

        let cleared = Set(items.filter { moved.contains($0.id) }.map(\.contentHash))
        for old in earlier where cleared.contains(old.contentHash) && !moved.contains(old.id) {
            archive.delete(id: old.id)
            // Deleting touched the archive, and so its date.
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: archiveRoot.path)
        }
        removeArchiveIfEmpty()

        // Whatever is not left on disk is gone from the history, so the
        // list never shows an item whose files have moved.
        let before = items.count
        items.removeAll { !left.contains($0.id) }
        guard items.count != before else { return 0 }
        onChange?()
        return before - items.count
    }

    /// The archive folder is only kept while it holds something.
    private func removeArchiveIfEmpty() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: archiveRoot.path),
              !names.contains(where: { UUID(uuidString: $0) != nil })
        else { return }
        try? fm.removeItem(at: archiveRoot)
    }

    /// The archived history, if there is one.
    public var archiveSummary: ArchiveSummary? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: archiveRoot.path) else { return nil }
        let count = names.filter { UUID(uuidString: $0) != nil }.count
        guard count > 0,
              let date = (try? fm.attributesOfItem(atPath: archiveRoot.path))?[.modificationDate] as? Date
        else { return nil }
        return ArchiveSummary(count: count, archivedAt: date)
    }

    /// Deletes the archive for good.
    public func deleteArchive() {
        try? FileManager.default.removeItem(at: archiveRoot)
    }

    /// Deletes the archive once it is older than `archiveLifetime`, or
    /// when it holds nothing. Returns whether it was deleted.
    @discardableResult
    public func expireArchive(now: Date) -> Bool {
        guard FileManager.default.fileExists(atPath: archiveRoot.path) else { return false }
        if let summary = archiveSummary,
           now.timeIntervalSince(summary.archivedAt) < Self.archiveLifetime {
            return false
        }
        deleteArchive()
        return true
    }

    /// Puts back as many archived items as the history has room for,
    /// newest first by when each was last used, merged with what was
    /// copied since. The rest stay in the archive, so a restore never
    /// deletes an item or pushes one out of the history. The only thing
    /// it removes from the archive besides what came back is a copy of
    /// something already in the history. An item that could not be
    /// moved stays there too, with the archive's date, to be restored
    /// later.
    @discardableResult
    public func restoreArchive() -> RestoreResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveRoot.path) else { return RestoreResult(restored: 0, noRoom: 0) }
        let archivedAt = (try? fm.attributesOfItem(atPath: archiveRoot.path))?[.modificationDate]
        let archive = ItemStorage(root: archiveRoot)
        var seen = Set(items.map(\.contentHash))
        var waiting: [ClipItem] = []
        // Newest first, so a second copy of the same content is the older.
        for item in archive.loadAll() {
            if seen.insert(item.contentHash).inserted {
                waiting.append(item)
            } else {
                archive.delete(id: item.id)
            }
        }

        let room = max(limit - items.count, 0)
        var restored = 0
        var tried = 0
        for item in waiting where restored < room {
            tried += 1
            do {
                try archive.move(id: item.id, to: storage)
                items.append(item)
                restored += 1
            } catch {
                Self.logger.error("Could not restore item: \(error.localizedDescription, privacy: .public)")
            }
        }
        removeArchiveIfEmpty()
        if let archivedAt {
            // Moving items out touched what is left of the archive.
            try? fm.setAttributes([.modificationDate: archivedAt], ofItemAtPath: archiveRoot.path)
        }
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
