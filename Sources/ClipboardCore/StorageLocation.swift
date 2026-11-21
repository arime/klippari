import Foundation

/// Where the history lives on disk:
///
///     ~/Library/Application Support/Klippari/
///         .metadata_never_index
///         items.noindex/            the history
///         items-archive.noindex/    the cleared history
///
/// The '.noindex' suffix keeps Spotlight from indexing the history. The
/// marker file is only a further hint: Spotlight is known to honour it
/// at a volume's root, not necessarily in a folder. The folder is also
/// excluded from backups.
public enum StorageLocation {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klippari")
    }

    public static func itemsRoot(in folder: URL) -> URL {
        folder.appendingPathComponent("items.noindex")
    }

    /// Where a run that cannot save keeps its items: a new folder in
    /// `caches`, Klippari's folder in the user's Caches. Unlike the
    /// temporary folder, which macOS empties of files left unread for a
    /// few days, it lasts as long as the run. The folder names this
    /// process as its owner, so another Klippari leaves it alone.
    public static func unsavedItemsRoot(in caches: URL) -> URL {
        let folder = caches.appendingPathComponent(unsavedPrefix + UUID().uuidString + ".noindex")
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(
            atPath: folder.appendingPathComponent(ownerName).path,
            contents: Data(String(getpid()).utf8), attributes: [.posixPermissions: 0o600]
        )
        return folder.appendingPathComponent("items")
    }

    /// Deletes the folders of unsaved runs that ended without cleaning up
    /// (a crash, a kill, a logout), at every launch. Their key was only
    /// ever in memory, so nothing in them can be read. A folder whose
    /// owner is still running is kept.
    public static func removeAbandonedUnsaved(
        in caches: URL, isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: caches.path)) ?? [] where name.hasPrefix(unsavedPrefix) {
            let folder = caches.appendingPathComponent(name)
            let owner = (try? String(contentsOf: folder.appendingPathComponent(ownerName), encoding: .utf8))
                .flatMap { pid_t($0) }
            if let owner, isRunning(owner) { continue }
            try? fm.removeItem(at: folder)
        }
    }

    public static var defaultCaches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arime.Klippari")
    }

    private static let unsavedPrefix = "unsaved-"
    private static let ownerName = "owner"

    /// The archive next to an items folder: 'items.noindex' archives to
    /// 'items-archive.noindex'.
    public static func archiveRoot(forItems root: URL) -> URL {
        var base = root.lastPathComponent
        if base.hasSuffix(".noindex") { base.removeLast(".noindex".count) }
        return root.deletingLastPathComponent().appendingPathComponent(base + "-archive.noindex")
    }

    /// Makes the folder private (0700), keeps it out of Spotlight and
    /// backups, and moves history kept under version 1.0's names
    /// ('items', 'items-archive') to their '.noindex' names. Safe to call
    /// on every launch.
    public static func prepare(_ folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

        let marker = folder.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            fm.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        // Best effort, like the marker: the history is encrypted either
        // way, so a folder that refuses this still saves.
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)

        let items = itemsRoot(in: folder)
        try moveLegacy(folder.appendingPathComponent("items"), to: items)
        let archive = archiveRoot(forItems: items)
        if try moveLegacy(folder.appendingPathComponent("items-archive"), to: archive) {
            // A flat archive from an earlier build is dated by the
            // folder's modification time. It gets the full 24 hours from
            // now, rather than vanishing on this first launch. Clears in
            // their own folders keep their dates, which are in the names.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: archive.path)
        }
    }

    /// Renames `legacy` to `current`. When both exist, the legacy items
    /// are moved over (an item already in `current` wins), and so are the
    /// items of a legacy clear whose folder name `current` already has.
    /// The legacy folder is removed once it is empty; if any move fails
    /// it stays, to be tried again on the next launch. Returns whether
    /// anything was moved.
    @discardableResult
    private static func moveLegacy(_ legacy: URL, to current: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return false }
        if !fm.fileExists(atPath: current.path) {
            try fm.moveItem(at: legacy, to: current)
        } else if merge(legacy, into: current) {
            try fm.removeItem(at: legacy)
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        return true
    }

    /// Moves what is in `source` into `destination`. An item (a folder
    /// named by its identifier) already in `destination` wins; a folder
    /// that is not an item, such as a clear, is merged into its namesake.
    /// Returns whether everything was moved, so `source` can go.
    private static func merge(_ source: URL, into destination: URL) -> Bool {
        let fm = FileManager.default
        var allMoved = true
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            do {
                if (try? fm.attributesOfItem(atPath: to.path)) == nil {
                    try fm.moveItem(at: from, to: to)
                } else if UUID(uuidString: name) == nil, fm.isRealDirectory(from), fm.isRealDirectory(to) {
                    if merge(from, into: to) { try fm.removeItem(at: from) } else { allMoved = false }
                } else {
                    try fm.removeItem(at: from)
                }
            } catch {
                allMoved = false
            }
        }
        return allMoved
    }
}
