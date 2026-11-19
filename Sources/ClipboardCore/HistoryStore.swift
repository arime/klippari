import Foundation
import os

/// The last cleared history, which can be restored.
public struct ArchiveSummary: Equatable, Sendable {
    public var count: Int
    public var archivedAt: Date

    public init(count: Int, archivedAt: Date) {
        self.count = count
        self.archivedAt = archivedAt
    }
}

/// The ordered history, newest first, mirrored to disk. Items in memory
/// carry lightened content (text and file URLs only); images and other
/// large data stay on disk until an item is pasted.
@MainActor public final class HistoryStore {
    private let storage: ItemStorage
    /// Where clearing the history moves it, so the last clear can be
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

    /// Clears the history by moving it to the archive, replacing the
    /// previous archive. Returns how many items were cleared; 0 when there
    /// was nothing to clear or the move failed, and then nothing changes.
    @discardableResult
    public func archiveAll(now: Date) -> Int {
        let count = items.count
        guard count > 0 else { return 0 }
        do {
            try storage.archiveAll(to: archiveRoot, at: now)
        } catch {
            Self.logger.error("Could not archive history: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        items.removeAll()
        onChange?()
        return count
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

    /// Puts the archived items back, merged with what was copied since by
    /// when each was last used, and removes the archive. Items already in
    /// the history are not added twice, and the history size still
    /// applies. Returns how many items came back.
    @discardableResult
    public func restoreArchive() -> Int {
        guard FileManager.default.fileExists(atPath: archiveRoot.path) else { return 0 }
        let archive = ItemStorage(root: archiveRoot)
        let present = Set(items.map(\.contentHash))
        var restored = 0
        for item in archive.loadAll() where !present.contains(item.contentHash) {
            do {
                try archive.move(id: item.id, to: storage)
                items.append(item)
                restored += 1
            } catch {
                Self.logger.error("Could not restore item: \(error.localizedDescription, privacy: .public)")
            }
        }
        try? FileManager.default.removeItem(at: archiveRoot)
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
        trim()
        onChange?()
        return restored
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
