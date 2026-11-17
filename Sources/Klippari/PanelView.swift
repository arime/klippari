import AppKit
import ClipboardCore
import SwiftUI

/// Sizes taken from the Paper mock ('Panel – default').
enum PanelMetrics {
    static let cardWidth: CGFloat = 640
    static let rowHeight: CGFloat = 44
    /// Nine, so every row a Cmd+digit can paste is in view when the
    /// panel opens.
    static let visibleRows = 9
    static let listPadding: CGFloat = 6
    static let searchHeight: CGFloat = 56
    static let footerHeight: CGFloat = 36
    /// Transparent margin around the card that holds its shadow.
    static let shadowInset: CGFloat = 60

    /// The app's one colour (#0A5CFF), shared with the app icon. Fixed
    /// rather than the system accent so the panel always matches the icon.
    static let blue = Color(red: 0.039, green: 0.361, blue: 1)

    static var maxCardHeight: CGFloat {
        searchHeight + CGFloat(visibleRows) * rowHeight + 2 * listPadding + footerHeight + 2
    }

    static var windowSize: NSSize {
        NSSize(width: cardWidth + 2 * shadowInset, height: maxCardHeight + 2 * shadowInset)
    }
}

/// Behind-window blur, which SwiftUI materials cannot do in a
/// transparent window.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelView: View {
    @Bindable var model: PanelModel
    var focus: PanelFocus
    let storage: ItemStorage
    /// Snapshots render offscreen, where behind-window blur draws nothing.
    var opaqueBackground = false
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: PanelMetrics.cardWidth)
        .background {
            if opaqueBackground {
                Color(nsColor: .windowBackgroundColor)
            } else {
                PanelBackground()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
        .padding(PanelMetrics.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { filterFocused = true }
        .onChange(of: focus.showCount) { filterFocused = true }
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Type to filter", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($filterFocused)
            Text(model.countLabel)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.searchHeight)
    }

    @ViewBuilder private var list: some View {
        if model.rows.isEmpty {
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 2 * PanelMetrics.rowHeight)
        } else {
            let appWidth = appColumnWidth
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            RowView(
                                row: row, isSelected: row.id == model.selectedID,
                                appWidth: appWidth, thumbnailURL: storage.thumbnailURL(for: row.id)
                            )
                            .id(row.id)
                        }
                    }
                    .padding(PanelMetrics.listPadding)
                }
                .frame(height: listHeight)
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                // The list keeps its scroll position while the panel is
                // hidden, and reopening selects the first row again, which
                // is no change of selection. Scroll to it on every open, or
                // a list scrolled by trackpad would reopen with the
                // selected row out of sight.
                .onChange(of: focus.showCount) {
                    if let id = model.selectedID { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    private var listHeight: CGFloat {
        let shown = min(model.rows.count, PanelMetrics.visibleRows)
        return CGFloat(shown) * PanelMetrics.rowHeight + 2 * PanelMetrics.listPadding
    }

    /// As wide as the longest app name on show, capped, so the app and
    /// age columns line up without wasting space on short names.
    private var appColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widest = model.rows
            .map { ($0.sourceApp as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(ceil(widest), 110)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 20) {
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.primary)
                Spacer()
            } else {
                KeyHint(keys: "↩", label: "Paste")
                KeyHint(keys: "⇧ ↩", label: "Paste as plain text")
                KeyHint(keys: "⌘ 1–9", label: "Quick paste")
                Spacer()
                KeyHint(keys: "⌘ ⌫", label: "Delete")
                KeyHint(keys: "esc", label: "Close")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.footerHeight)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RowView: View {
    let row: PanelModel.Row
    let isSelected: Bool
    let appWidth: CGFloat
    let thumbnailURL: URL

    private var primary: Color { isSelected ? .white : .primary }
    private var secondary: Color { isSelected ? .white.opacity(0.8) : .secondary }

    var body: some View {
        HStack(spacing: 12) {
            Text(row.number.map(String.init) ?? "")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(secondary)
                .frame(width: 16, alignment: .trailing)

            icon
                .frame(width: 28, height: 28)

            title
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(row.sourceApp)
                    .lineLimit(1)
                    .frame(width: appWidth, alignment: .leading)
                Text(row.age)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 13))
            .foregroundStyle(secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.rowHeight)
        .background(
            isSelected ? PanelMetrics.blue : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var title: Text {
        let main = Text(row.presentation.title)
            .font(.system(size: 15, weight: isSelected ? .medium : .regular))
            .foregroundStyle(primary)
        guard let tag = row.presentation.tag else { return main }
        // An image's tag follows its title directly; other tags are set
        // off with a dot, as in the mock.
        let separator = row.presentation.kind == .image ? " " : " · "
        return main + Text(separator + tag).font(.system(size: 15)).foregroundStyle(secondary)
    }

    @ViewBuilder private var icon: some View {
        if row.presentation.kind == .image, let image = NSImage(contentsOf: thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        }
    }

    private var symbolName: String {
        switch row.presentation.kind {
        case .text: "text.alignleft"
        case .styledText: "textformat"
        case .link: "link"
        case .file: "doc"
        case .image: "photo"
        case .other: "questionmark.square"
        }
    }
}
