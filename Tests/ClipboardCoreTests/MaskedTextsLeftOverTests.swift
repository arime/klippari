import Foundation
import Testing
import ClipboardCore

@MainActor @Suite struct MaskedTextsLeftOverTests {
    @Test func theFileEarlierBuildsWroteIsDeleted() throws {
        let root = temporaryRoot()
        _ = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        let folder = root.deletingLastPathComponent()
        let file = folder.appendingPathComponent("items-masked-texts")
        let staged = folder.appendingPathComponent(".tmp-items-masked-texts")
        try Data("sealed texts".utf8).write(to: file)
        try Data("sealed texts".utf8).write(to: staged)
        _ = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func besideANoIndexFolderToo() throws {
        let root = temporaryRoot().deletingLastPathComponent().appendingPathComponent("items.noindex")
        let folder = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("items-masked-texts")
        try Data("sealed texts".utf8).write(to: file)
        _ = HistoryStore(storage: ItemStorage(root: root, cipher: testCipher))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
