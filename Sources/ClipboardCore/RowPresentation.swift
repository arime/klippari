import Foundation
import UniformTypeIdentifiers

public enum ItemKind: Equatable, Sendable {
    case text, styledText, link, file, image, other
}

/// What one history item looks like as a row in the panel.
public struct RowPresentation: Equatable, Sendable {
    public var kind: ItemKind
    /// One line, no newlines.
    public var title: String
    /// Greyed suffix after the title.
    public var tag: String?
    /// Lowercased text, file names and source app.
    public var searchText: String

    public init(_ item: ClipItem) {
        let content = item.content
        let files = content.fileURLs
        let string = content.plainString
        var searchParts: [String] = []

        // A file URL wins over text: Finder puts the file name on the
        // pasteboard as plain text alongside the URL.
        if !files.isEmpty {
            kind = .file
            title = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            tag = "file"
            searchParts = files.map(\.lastPathComponent)
        } else if let info = item.imageInfo {
            kind = .image
            title = "Image"
            tag = "\(info.width) × \(info.height) · \(info.format)"
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

        if let app = item.sourceApp { searchParts.append(app) }
        searchText = searchParts.joined(separator: "\n").lowercased()
    }

    private static func isLink(_ line: String) -> Bool {
        guard !line.contains(where: \.isWhitespace),
              let url = URL(string: line),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return url.host != nil
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
