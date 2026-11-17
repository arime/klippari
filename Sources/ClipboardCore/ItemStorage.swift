import Foundation

/// Keeps history items on disk, one directory per item:
///
///     <root>/<uuid>/manifest.json
///     <root>/<uuid>/e<entry>-t<type>.bin   raw bytes of one pasteboard type
///     <root>/<uuid>/thumb.png              only for images
///
/// Data file names come from indices, never from the type string, because
/// type identifiers are arbitrary text chosen by other apps.
public struct ItemStorage: Sendable {
    public enum StorageError: Error {
        /// A lightened item was passed where full content is needed.
        case incompleteContent
        case missingItem
    }

    public let root: URL

    private struct Manifest: Codable {
        struct TypeRecord: Codable {
            var type: String
            var file: String
        }

        var id: UUID
        var capturedAt: Date
        var lastUsedAt: Date
        var sourceApp: String?
        var imageInfo: ImageInfo?
        /// Absent in manifests written before hashes were stored.
        var contentHash: String?
        var entries: [[TypeRecord]]
    }

    private static let manifestName = "manifest.json"
    private static let thumbnailName = "thumb.png"
    private static let temporaryPrefix = ".tmp-"

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klippari")
            .appendingPathComponent("items")
    }

    public init(root: URL) {
        self.root = root
        let fm = FileManager.default
        try? fm.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString)
    }

    public func thumbnailURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent(Self.thumbnailName)
    }

    /// Writes a new item with its full content. The item is built in a
    /// hidden temporary directory and renamed into place, so a visible
    /// item directory is always complete.
    public func save(_ item: ClipItem) throws {
        guard item.content.isComplete else { throw StorageError.incompleteContent }
        let fm = FileManager.default
        let temporary = root.appendingPathComponent(Self.temporaryPrefix + item.id.uuidString)
        try? fm.removeItem(at: temporary)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)

        do {
            var records: [[Manifest.TypeRecord]] = []
            for (entryIndex, entry) in item.content.entries.enumerated() {
                var entryRecords: [Manifest.TypeRecord] = []
                for (typeIndex, typed) in entry.types.enumerated() {
                    guard let data = typed.data else { continue }
                    let file = "e\(entryIndex)-t\(typeIndex).bin"
                    try data.write(to: temporary.appendingPathComponent(file))
                    entryRecords.append(Manifest.TypeRecord(type: typed.type, file: file))
                }
                records.append(entryRecords)
            }
            if item.imageInfo != nil, let thumbnail = ImageInfo.thumbnailPNG(item.content) {
                try thumbnail.write(to: temporary.appendingPathComponent(Self.thumbnailName))
            }
            let manifest = Manifest(
                id: item.id, capturedAt: item.capturedAt, lastUsedAt: item.lastUsedAt,
                sourceApp: item.sourceApp, imageInfo: item.imageInfo,
                contentHash: item.contentHash, entries: records
            )
            try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent(Self.manifestName))

            let destination = directory(for: item.id)
            if fm.fileExists(atPath: destination.path) {
                // Swap in one step, so an interruption never leaves the
                // item with neither the old nor the new directory.
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Records a change to an item's metadata (its last-used time) without
    /// touching its data files, which can be many megabytes.
    public func updateManifest(_ item: ClipItem) throws {
        let url = directory(for: item.id).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw StorageError.missingItem }
        manifest.capturedAt = item.capturedAt
        manifest.lastUsedAt = item.lastUsedAt
        manifest.sourceApp = item.sourceApp
        manifest.contentHash = item.contentHash
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    public func deleteAll() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Every item, newest `lastUsedAt` first, with lightened content: only
    /// text and file URL bytes are read. Directories that are not complete
    /// (interrupted writes, missing data files) are removed.
    public func loadAll() -> [ClipItem] {
        let fm = FileManager.default
        var items: [ClipItem] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if let item = loadItem(url), item.id.uuidString == name {
                items.append(item)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        return items.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// The item's full content, for pasting. Nil when it cannot all be read.
    public func loadContent(id: UUID) -> ClipContent? {
        let directory = directory(for: id)
        guard let manifest = manifest(in: directory) else { return nil }
        return content(of: manifest, in: directory, full: true)
    }

    private func manifest(in directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.manifestName)) else {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func loadItem(_ directory: URL) -> ClipItem? {
        guard let manifest = manifest(in: directory),
              let light = content(of: manifest, in: directory, full: false)
        else { return nil }

        var hash = manifest.contentHash
        if hash == nil {
            // Written before hashes were stored: compute it once from the
            // full content. It is saved the next time the manifest is.
            hash = content(of: manifest, in: directory, full: true)?.contentHash
        }
        guard let hash else { return nil }
        return ClipItem(
            id: manifest.id, capturedAt: manifest.capturedAt, lastUsedAt: manifest.lastUsedAt,
            sourceApp: manifest.sourceApp, content: light, imageInfo: manifest.imageInfo,
            contentHash: hash
        )
    }

    /// With `full` false, bytes are read only for the types kept in
    /// memory; the other data files are just checked for existence.
    private func content(of manifest: Manifest, in directory: URL, full: Bool) -> ClipContent? {
        let fm = FileManager.default
        var entries: [PasteboardEntry] = []
        for records in manifest.entries {
            var types: [TypedData] = []
            for record in records {
                // Only ever touch a plain file name inside the item directory.
                guard record.file == (record.file as NSString).lastPathComponent else { return nil }
                let url = directory.appendingPathComponent(record.file)
                if full || TypeName.keptInMemory.contains(record.type) {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    types.append(TypedData(type: record.type, data: data))
                } else {
                    guard fm.fileExists(atPath: url.path) else { return nil }
                    types.append(TypedData(type: record.type, data: nil))
                }
            }
            entries.append(PasteboardEntry(types: types))
        }
        return ClipContent(entries: entries)
    }
}
