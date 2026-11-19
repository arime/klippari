import Foundation

/// Where the history lives on disk:
///
///     ~/Library/Application Support/Klippari/
///         .metadata_never_index
///         items.noindex/            the history
///         items-archive.noindex/    the cleared history
///
/// The '.noindex' suffix and the marker file keep Spotlight from indexing
/// the history, and the folder is excluded from backups.
public enum StorageLocation {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klippari")
    }

    public static func itemsRoot(in folder: URL) -> URL {
        folder.appendingPathComponent("items.noindex")
    }

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

        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)

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
    /// are moved over (an item already in `current` wins) and the legacy
    /// folder is removed once it is empty; if any move fails it stays,
    /// to be tried again on the next launch. Returns whether anything
    /// was moved.
    @discardableResult
    private static func moveLegacy(_ legacy: URL, to current: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return false }
        if !fm.fileExists(atPath: current.path) {
            try fm.moveItem(at: legacy, to: current)
        } else {
            var allMoved = true
            for name in (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? [] {
                let source = legacy.appendingPathComponent(name)
                let destination = current.appendingPathComponent(name)
                do {
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: source)
                    } else {
                        try fm.moveItem(at: source, to: destination)
                    }
                } catch {
                    allMoved = false
                }
            }
            if allMoved { try fm.removeItem(at: legacy) }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        return true
    }
}
