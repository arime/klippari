import AppKit

/// The system clipboard, behind a seam so the monitor can be tested.
@MainActor public protocol PasteboardClient: AnyObject {
    /// Increases every time the pasteboard's contents change.
    var changeCount: Int { get }
    /// Every item and every type; `data` is nil where it was not read.
    func read() -> ClipContent
    /// Replaces the contents and returns the resulting change count.
    func write(_ content: ClipContent) -> Int
}

@MainActor public final class SystemPasteboard: PasteboardClient {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    /// Reads no bytes at all from content that will not be recorded:
    /// anything a password manager marked as concealed, and whatever
    /// follows once the running total passes the capture size cap. Asking
    /// for data makes the source app produce it, so this also avoids
    /// forcing a large or slow copy to render every representation.
    public func read() -> ClipContent {
        let items = pasteboard.pasteboardItems ?? []
        let isMarked = items.contains { item in
            item.types.contains { TypeName.skipMarkers.contains($0.rawValue) }
        }
        var total = 0
        let entries = items.map { item in
            PasteboardEntry(types: item.types.map { type in
                guard !isMarked, total <= CaptureFilter.maxBytes else {
                    return TypedData(type: type.rawValue, data: nil)
                }
                let data = item.data(forType: type)
                total += data?.count ?? 0
                return TypedData(type: type.rawValue, data: data)
            })
        }
        return ClipContent(entries: entries)
    }

    public func write(_ content: ClipContent) -> Int {
        pasteboard.clearContents()
        let items = content.entries.map { entry in
            let item = NSPasteboardItem()
            for typed in entry.types {
                if let data = typed.data {
                    item.setData(data, forType: NSPasteboard.PasteboardType(typed.type))
                }
            }
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }
}
