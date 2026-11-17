import Foundation

/// Decides whether a raw pasteboard read becomes a history item.
public enum CaptureFilter {
    public static let maxBytes = 20 * 1024 * 1024

    /// Returns the content to record, with unreadable types removed, or nil
    /// when the copy must not be recorded at all.
    public static func accept(_ raw: ClipContent) -> ClipContent? {
        let isMarked = raw.entries.contains { entry in
            entry.types.contains { TypeName.skipMarkers.contains($0.type) }
        }
        if isMarked { return nil }

        let entries = raw.entries
            .map { PasteboardEntry(types: $0.types.filter { $0.data != nil }) }
            .filter { !$0.types.isEmpty }
        if entries.isEmpty { return nil }

        let content = ClipContent(entries: entries)
        if content.totalBytes > maxBytes { return nil }
        return content
    }
}
