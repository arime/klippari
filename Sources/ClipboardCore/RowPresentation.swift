import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ItemKind: Equatable, Sendable {
    case text, styledText, link, file, image, other
}

/// A colour swatch that tells rows apart while Presentation Mode hides
/// what they hold, worked out from the item's content with a key made
/// afresh each launch. The same content gets the same colour for as
/// long as the app runs, and nobody watching can work back from a
/// colour to the content.
public struct RowMarker: Equatable, Sendable {
    /// 0..<`RowMarker.hueCount`, an index into the view's palette.
    public let hue: Int

    public static let hueCount = 12

    /// Every secret shows this one, outside the content hues: a colour
    /// of its own would tell a viewer the same secret was copied again.
    public static let secret = RowMarker(hue: hueCount)

    private init(hue: Int) { self.hue = hue }

    init(contentHash: String, key: SymmetricKey) {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(contentHash.utf8), using: key)
        let bytes = Array(mac)
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        hue = Int(value % UInt32(Self.hueCount))
    }
}

/// What one history item looks like as a row in the panel.
public struct RowPresentation: Equatable, Sendable {
    public var kind: ItemKind
    /// One line, no newlines.
    public var title: String
    /// Greyed suffix after the title.
    public var tag: String?
    /// Lowercased text, file names and source app; for an image, also
    /// 'image' and its format. With contents hidden, only what the row
    /// shows: its kind, tag and source app.
    public var searchText: String
    /// Set while Presentation Mode hides the contents (see `init`).
    public var marker: RowMarker?
    /// The first few characters of the text or file name, shown in place
    /// of the title only while the user holds Option on the selected row
    /// in Presentation Mode. Nil for images, secrets and other kinds.
    public var peek: String?
    /// In Presentation Mode, the files whose total size the tag can
    /// show once it is known; the size is read off the main thread
    /// (`totalSize(of:)`) and added with `withFileSize(_:)`.
    public var sizedFiles: [URL] = []

    /// How many characters a peek shows.
    public static let peekLength = 6

    /// With `hidingContents` (Presentation Mode), the row shows what kind
    /// of item it is and nothing of what it holds: no text, link, file
    /// name or thumbnail; a file's types and size, an image's size and
    /// format, and a `marker` made with `markerKey` stand in. A secret
    /// shows as 'Secret', without even its masked line.
    public init(_ item: ClipItem, hidingContents: Bool = false, markerKey: SymmetricKey? = nil) {
        let content = item.content
        let files = content.fileURLs
        let string = content.plainString
        var searchParts: [String] = []

        // A file URL wins over text: Finder puts the file name on the
        // pasteboard as plain text alongside the URL. It also wins over
        // image data, since Finder adds the file's icon, unless the copy
        // is an image that is also offered as its saved file.
        let imageIsTheFile = item.imageInfo != nil && Self.isImageOfferedAsFile(content, files)
        if item.isSecret {
            // Only the masked first line shows, and only it is searched,
            // so typing in the filter cannot confirm the hidden part.
            // Nothing else about the secret shows either: not that it is
            // a link, nor its number of lines, nor a file's name.
            kind = .text
            let firstLine = string?
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            title = firstLine.map(Secrets.mask) ?? Secrets.dots
            tag = nil
            searchParts = [title, "secret"]
        } else if !files.isEmpty, !imageIsTheFile {
            kind = .file
            title = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            tag = "file"
            searchParts = files.map(\.lastPathComponent)
        } else if let info = item.imageInfo {
            kind = .image
            title = "Image"
            tag = "\(info.width) × \(info.height) · \(info.format)"
            searchParts = files.map(\.lastPathComponent)
        } else if let string {
            let lines = string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            title = lines.first ?? "Empty text"
            searchParts = [string]
            if content.hasType(TypeName.rtf) || content.hasType(TypeName.html) {
                kind = .styledText
                tag = "styled"
            } else if lines.count == 1, Self.isLink(lines[0]) {
                kind = .link
                tag = nil
            } else {
                kind = .text
                tag = lines.count > 1 ? "\(lines.count) lines" : nil
            }
        } else {
            kind = .other
            let type = content.entries.first?.types.first?.type ?? ""
            title = UTType(type)?.localizedDescription ?? (type.isEmpty ? "Unknown" : type)
            tag = nil
        }

        // An image has no text of its own, so without these words it
        // could only be found by its source app. Other kinds get none:
        // 'text' or 'file' would match nearly every item.
        if kind == .image {
            searchParts.append("image")
            if let format = item.imageInfo?.format { searchParts.append(format) }
        }
        if let app = item.sourceApp { searchParts.append(app) }
        searchText = searchParts.joined(separator: "\n").lowercased()
        if hidingContents {
            if item.isSecret {
                // Not even a secret's masked line: its known prefix and last
                // characters would be on the stream.
                title = "Secret"
                tag = nil
                peek = nil
            } else {
                hideContents(files: files, string: string)
            }
            // Only what the row shows can be searched, so typing in the
            // filter cannot confirm what is hidden.
            searchText = [title, tag, item.sourceApp].compactMap { $0 }.joined(separator: "\n").lowercased()
            if item.isSecret {
                marker = .secret
            } else if let markerKey {
                marker = RowMarker(contentHash: item.contentHash, key: markerKey)
            }
        }
    }

    /// Replaces the title and tag with what may show while contents are
    /// hidden, and works out the peek.
    private mutating func hideContents(files: [URL], string: String?) {
        let firstLine = string?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        switch kind {
        case .text, .styledText:
            // The line count stays: '3 lines' says nothing of the text.
            // Any other tag (a styled text's) goes.
            let lines = tag.flatMap { $0.hasSuffix("lines") ? $0 : nil }
            title = kind == .text ? "Text" : "Styled text"
            tag = lines
            peek = firstLine.map(Self.peek)
        case .link:
            title = "Link"
            tag = nil
            peek = firstLine.map { line in
                Self.peek(line.replacingOccurrences(
                    of: "^https?://(www\\.)?", with: "", options: [.regularExpression, .caseInsensitive]
                ))
            }
        case .file:
            title = files.count == 1 ? (files[0].hasDirectoryPath ? "Folder" : "File") : "\(files.count) files"
            tag = Self.fileTypes(files)
            sizedFiles = files
            peek = files.first.map { Self.peek($0.lastPathComponent) }
        case .image:
            peek = nil
        case .other:
            // The type's name can say which app the copy came from, or
            // what it is; the app shows anyway, and the rest need not.
            title = "Other"
            tag = nil
            peek = nil
        }
    }

    private static func peek(_ text: String) -> String {
        text.count > peekLength ? String(text.prefix(peekLength)) + "…" : text
    }

    /// The files' types: 'pdf', 'pdf, png'. Only extensions the system
    /// knows as a type show, so a name like 'Clients.AcmeMerger' does
    /// not give its last part away.
    private static func fileTypes(_ files: [URL]) -> String? {
        var types: [String] = []
        for file in files {
            let type = file.pathExtension.lowercased()
            guard !type.isEmpty, !types.contains(type),
                  let known = UTType(filenameExtension: type), !known.isDynamic
            else { continue }
            types.append(type)
        }
        guard !types.isEmpty else { return nil }
        return types.prefix(3).joined(separator: ", ") + (types.count > 3 ? "…" : "")
    }

    /// The files' total size, when every one is a regular file that can
    /// be read. Touches the disk, so it is called off the main thread.
    public static func totalSize(of files: [URL]) -> Int64? {
        var total: Int64 = 0
        for file in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else { return nil }
            total += size
        }
        return files.isEmpty ? nil : total
    }

    /// This row with the files' total size added to its tag:
    /// 'pdf · 2.3 MB'. The size can be searched, like the rest of the tag.
    public func withFileSize(_ bytes: Int64) -> RowPresentation {
        var row = self
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        row.tag = [tag, size].compactMap { $0 }.joined(separator: " · ")
        row.searchText = searchText + "\n" + size.lowercased()
        return row
    }

    /// True for a single image file that comes with its own PNG bytes, as
    /// screenshot helpers such as clipaste write it so that terminals can
    /// paste a path. Finder's icon for a copied file is not PNG.
    private static func isImageOfferedAsFile(_ content: ClipContent, _ files: [URL]) -> Bool {
        guard files.count == 1, content.hasType(TypeName.png),
              let type = UTType(filenameExtension: files[0].pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    private static func isLink(_ line: String) -> Bool {
        guard !line.contains(where: \.isWhitespace),
              let url = URL(string: line),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return url.host != nil
    }

    /// What VoiceOver reads for a secret's title: the dots as the word
    /// 'hidden' rather than one 'bullet' each.
    public var spokenTitle: String {
        title.replacingOccurrences(of: Secrets.dots, with: " hidden ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Case-insensitive substring match; an empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || searchText.contains(needle)
    }
}

/// Compact age for the row's right-hand column.
public func ageString(from date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60) min" }
    if seconds < 86400 { return "\(seconds / 3600) h" }
    return "\(seconds / 86400) d"
}

/// Time left before a secret leaves the history, in whole minutes rounded
/// up, so it reads '1 min' until the very end.
public func remainingString(until date: Date, now: Date) -> String {
    let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    return "\(minutes) min"
}
