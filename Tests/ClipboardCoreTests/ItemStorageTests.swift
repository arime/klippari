import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ClipboardCore

func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardCoreTests-\(UUID().uuidString)")
        .appendingPathComponent("items")
}

func makeItem(
    _ content: ClipContent, lastUsed: TimeInterval = 0, sourceApp: String? = "Notes", imageInfo: ImageInfo? = nil
) -> ClipItem {
    ClipItem(
        id: UUID(), capturedAt: Date(timeIntervalSince1970: 1000),
        lastUsedAt: Date(timeIntervalSince1970: 1000 + lastUsed),
        sourceApp: sourceApp, content: content, imageInfo: imageInfo
    )
}

/// What the history holds in memory for an item: same metadata and hash,
/// content reduced to text and file URLs.
func lightened(_ item: ClipItem) -> ClipItem {
    ClipItem(
        id: item.id, capturedAt: item.capturedAt, lastUsedAt: item.lastUsedAt,
        sourceApp: item.sourceApp, content: item.content.lightened,
        imageInfo: item.imageInfo, contentHash: item.contentHash
    )
}

@Suite struct ItemStorageTests {
    @Test func roundTripsMultiEntryContent() throws {
        let storage = ItemStorage(root: temporaryRoot())
        let item = makeItem(ClipContent(entries: [
            PasteboardEntry(types: [typed(TypeName.plainText, "hello"), typed(TypeName.rtf, "{\\rtf1 hello}")]),
            PasteboardEntry(types: [typed(TypeName.fileURL, "file:///tmp/a.pdf"), typed(TypeName.plainText, "a.pdf")]),
        ]))
        try storage.save(item)
        #expect(storage.loadContent(id: item.id) == item.content)
        #expect(storage.loadAll() == [lightened(item)])
    }

    @Test func roundTripsNilSourceApp() throws {
        let storage = ItemStorage(root: temporaryRoot())
        let item = makeItem(content(typed(TypeName.plainText, "x")), sourceApp: nil)
        try storage.save(item)
        #expect(storage.loadAll() == [item])
    }

    @Test func roundTripsUnsafeTypeName() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root)
        let item = makeItem(content(typed("text/html; charset=utf-8", "<b>x</b>"), typed("../evil", "y")))
        try storage.save(item)
        #expect(storage.loadContent(id: item.id) == item.content)
        #expect(storage.loadAll() == [lightened(item)])
        let top = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(top == [item.id.uuidString])
        let parent = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
        #expect(parent == ["items"])
    }

    @Test func loadSkipsAndRemovesBrokenItems() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root)
        let good = makeItem(content(typed(TypeName.plainText, "good")))
        try storage.save(good)

        let fm = FileManager.default
        let noManifest = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: noManifest, withIntermediateDirectories: true)

        let missingData = makeItem(content(typed(TypeName.plainText, "lost")))
        try storage.save(missingData)
        let missingDir = root.appendingPathComponent(missingData.id.uuidString)
        try fm.removeItem(at: missingDir.appendingPathComponent("e0-t0.bin"))

        let leftover = root.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        #expect(storage.loadAll() == [good])
        #expect(try fm.contentsOfDirectory(atPath: root.path) == [good.id.uuidString])
    }

    @Test func loadOrdersByLastUsed() throws {
        let storage = ItemStorage(root: temporaryRoot())
        let old = makeItem(content(typed(TypeName.plainText, "old")), lastUsed: 1)
        let newest = makeItem(content(typed(TypeName.plainText, "newest")), lastUsed: 3)
        let middle = makeItem(content(typed(TypeName.plainText, "middle")), lastUsed: 2)
        for item in [old, newest, middle] { try storage.save(item) }
        #expect(storage.loadAll().map(\.id) == [newest.id, middle.id, old.id])
    }

    @Test func saveReplacesExistingItem() throws {
        let storage = ItemStorage(root: temporaryRoot())
        var item = makeItem(content(typed(TypeName.plainText, "x")))
        try storage.save(item)
        item.lastUsedAt = Date(timeIntervalSince1970: 5000)
        try storage.save(item)
        #expect(storage.loadAll() == [item])
    }

    @Test func deleteRemovesDirectory() throws {
        let root = temporaryRoot()
        let storage = ItemStorage(root: root)
        let item = makeItem(content(typed(TypeName.plainText, "x")))
        try storage.save(item)
        storage.delete(id: item.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func rootIsPrivate() throws {
        let root = temporaryRoot()
        _ = ItemStorage(root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func saveWritesThumbnail() throws {
        let storage = ItemStorage(root: temporaryRoot())
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 200, height: 100)))
        let item = makeItem(png, imageInfo: ImageInfo.inspect(png))
        try storage.save(item)
        let thumb = try Data(contentsOf: storage.thumbnailURL(for: item.id))
        let info = ImageInfo.inspect(content(TypedData(type: TypeName.png, data: thumb)))
        #expect(info?.width == 56)
        #expect(info?.height == 28)
        #expect(storage.loadAll() == [lightened(item)])
    }
}

@Suite struct ImageInfoTests {
    @Test func inspectReadsPNG() {
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 4, height: 2)))
        #expect(ImageInfo.inspect(png) == ImageInfo(width: 4, height: 2, format: "PNG"))
    }

    @Test func inspectIgnoresText() {
        #expect(ImageInfo.inspect(content(typed(TypeName.plainText, "hi"))) == nil)
    }

    @Test func inspectIgnoresCorruptImageData() {
        #expect(ImageInfo.inspect(content(typed(TypeName.png, "not a png"))) == nil)
    }
}
