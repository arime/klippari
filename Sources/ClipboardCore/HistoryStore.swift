import Foundation
import os

/// The ordered history, newest first, mirrored to disk. Items in memory
/// carry lightened content (text and file URLs only); images and other
/// large data stay on disk until an item is pasted.
@MainActor public final class HistoryStore {
    private let storage: ItemStorage
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
