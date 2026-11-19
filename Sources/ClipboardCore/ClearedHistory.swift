import Foundation

/// The cleared history on disk: one folder per clear, named by when the
/// clear was made, each holding the cleared items as an `ItemStorage`:
///
///     items-archive/20261120T060413Z/<uuid>/manifest.json …
///
/// Folder names are UTC times in ISO 8601 basic format, so they sort by
/// date, and a clear's age is known from a directory listing alone,
/// without reading any item.
struct ClearedHistory {
    struct Clear {
        var date: Date
        var storage: ItemStorage
    }

    let root: URL
    /// Cleared items are encrypted like the history.
    let cipher: ItemCipher

    private static let nameStyle = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .gmt
    )

    /// Every clear, oldest first.
    func clears() -> [Clear] {
        let fm = FileManager.default
        var clears: [Clear] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let date = try? Date(name, strategy: Self.nameStyle) else { continue }
            let url = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            clears.append(Clear(date: date, storage: ItemStorage(root: url, cipher: cipher)))
        }
        return clears.sorted { $0.date < $1.date }
    }

    /// Where a clear made at `date` goes. Two clears within the same
    /// second share a folder.
    func storage(for date: Date) -> ItemStorage {
        ItemStorage(root: root.appendingPathComponent(date.formatted(Self.nameStyle)), cipher: cipher)
    }

    /// Every cleared item with the clear it is in, most recently used
    /// first.
    func items() -> [(item: ClipItem, clear: Clear)] {
        clears()
            .flatMap { clear in clear.storage.loadAll().map { (item: $0, clear: clear) } }
            .sorted { $0.item.lastUsedAt > $1.item.lastUsedAt }
    }

    /// Earlier builds kept the cleared history flat, with item folders
    /// directly in the root and one date for all of it, the root's
    /// modification time. That becomes one clear made at that time.
    func adoptFlatLayout() {
        let fm = FileManager.default
        let flat = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { UUID(uuidString: $0) != nil }
        guard !flat.isEmpty,
              let date = (try? fm.attributesOfItem(atPath: root.path))?[.modificationDate] as? Date
        else { return }
        let clear = storage(for: date)
        for name in flat {
            try? fm.moveItem(at: root.appendingPathComponent(name), to: clear.root.appendingPathComponent(name))
        }
        // Moving touched the root. Put its date back, so anything that
        // could not be moved gets the same date next time.
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }

    /// Deletes each clear once `lifetime` has passed since it was made.
    /// Returns whether any was deleted; one that could not be is left
    /// for the next check.
    func expire(now: Date, lifetime: TimeInterval) -> Bool {
        var deleted = false
        for clear in clears() where now.timeIntervalSince(clear.date) >= lifetime {
            if (try? FileManager.default.removeItem(at: clear.storage.root)) != nil {
                deleted = true
            }
        }
        removeEmpty()
        return deleted
    }

    /// When the oldest clear is due to be deleted.
    func nextExpiry(lifetime: TimeInterval) -> Date? {
        clears().first.map { $0.date.addingTimeInterval(lifetime) }
    }

    /// Deletes the oldest clears while all of them together take more
    /// than `limit` bytes. `kept`, the clear just made, is never deleted,
    /// so what was just cleared can be restored, however large it is.
    /// It is named rather than taken to be the newest: if the clock was
    /// set back since an earlier clear, the clear just made is not the
    /// newest by its name.
    func trim(toBytes limit: Int64, keeping kept: ItemStorage) {
        let clears = clears()
        let sizes = clears.map { Self.size(of: $0.storage.root) }
        var total = sizes.reduce(0, +)
        for (clear, size) in zip(clears, sizes) where total > limit {
            guard clear.storage.root.lastPathComponent != kept.root.lastPathComponent else { continue }
            try? FileManager.default.removeItem(at: clear.storage.root)
            total -= size
        }
    }

    /// Removes clears that hold no items, and the root once no clear is
    /// left.
    func removeEmpty() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var left = 0
        for clear in clears() {
            if Self.itemCount(in: clear.storage.root) == 0 {
                try? fm.removeItem(at: clear.storage.root)
            } else {
                left += 1
            }
        }
        let flat = names.contains { UUID(uuidString: $0) != nil }
        if left == 0, !flat {
            try? fm.removeItem(at: root)
        }
    }

    /// How many items there are and when the last clear was made; nil
    /// when nothing is cleared.
    var summary: ArchiveSummary? {
        let clears = clears()
        let count = clears.reduce(0) { $0 + Self.itemCount(in: $1.storage.root) }
        guard count > 0, let last = clears.last else { return nil }
        return ArchiveSummary(count: count, archivedAt: last.date, clears: clears.count)
    }

    private static func itemCount(in folder: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { UUID(uuidString: $0) != nil }.count
    }

    /// The bytes in the files under `folder`.
    private static func size(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
