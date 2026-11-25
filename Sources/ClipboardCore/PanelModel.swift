import CryptoKit
import Foundation
import Observation

/// State of the history panel: the filter, the visible rows and which
/// one Return will paste. Holds no UI code so it can be unit tested.
@MainActor @Observable public final class PanelModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// 1...9 for the rows Cmd+digit can paste; nil after that.
        public var number: Int?
        public var presentation: RowPresentation
        /// Empty when the source app is unknown.
        public var sourceApp: String
        public var age: String
        /// For a secret, how long until it leaves the history ('9 min').
        public var expiresIn: String?
    }

    public enum EscapeResult: Sendable {
        case clearedQuery, close
    }

    private let store: HistoryStore
    private let now: () -> Date
    /// Rows worked out before, by item. An item keeps its id when it is
    /// copied again as a secret, and its row must then be worked out
    /// again, masked; so must every row when Presentation Mode turns on
    /// or off. Nothing else about an item changes its row.
    private var presentations: [UUID: (isSecret: Bool, hidden: Bool, row: RowPresentation)] = [:]

    /// Presentation Mode: rows show what kind of item each is, not what
    /// it holds, for streaming or recording the screen. Nothing stored
    /// changes.
    public var hidesContents = false {
        didSet {
            guard hidesContents != oldValue else { return }
            peeking = false
            // Sizes read in an earlier spell may be out of date.
            fileSizes = [:]
            sizeGeneration += 1
            // With a filter typed the selected row may stop matching: the
            // first match is selected then, as when the filter changes.
            rebuild(keepingSelection: true, elseFirst: true)
        }
    }

    /// True while the user peeks in Presentation Mode: the selected row
    /// shows the first few characters of its text. Ends when the
    /// selection moves, however it moves, so a peek never runs down
    /// the list.
    public var peeking = false

    /// Total sizes of copied files, by content hash, read off the main
    /// thread: a network share that is gone can take long to answer.
    /// An entry is nil while it cannot be read.
    private var fileSizes: [String: Int64?] = [:]
    private var sizesBeingRead: Set<String> = []
    /// Set while a rebuild for sizes that came in is waiting: answers
    /// arriving together cost one rebuild, not one each.
    private var sizeRebuildPending = false
    /// Bumped when the sizes are let go, so a late answer is ignored.
    private var sizeGeneration = 0

    /// The key behind the rows' markers, made afresh each launch, so that
    /// nobody can work back from a marker to what the row holds. Shared
    /// by every panel model built in a run (Try Again, Reset Saved
    /// History), so a row keeps its colour until the app quits.
    private static let markerKey = SymmetricKey(size: .bits256)

    /// What the selected row shows in place of its title while the user
    /// peeks; nil for any other row, and when not peeking.
    public func peek(for row: Row) -> String? {
        guard hidesContents, peeking, row.id == selectedID else { return nil }
        return row.presentation.peek
    }

    /// The row Cmd+S just changed, kept in the list though it may no
    /// longer match the filter (a secret's row matches 'secret', its
    /// text in full does not), so that it stays selected and a second
    /// Cmd+S acts on it again, never on the next row. Let go when the
    /// filter changes, the selection moves or the panel opens.
    private var pinnedID: UUID?

    /// Typing in the panel edits this; the first match becomes selected.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            pinnedID = nil
            rebuild(keepingSelection: false)
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var selectedID: UUID? {
        didSet { if selectedID != oldValue, peeking { peeking = false } }
    }

    /// Something wrong that lasts, such as the history not being saved.
    /// Shown in the footer in place of the key hints on every open,
    /// until it is set back to nil; a `notice` shows over it.
    public var warning: String?
    /// Replaces the footer's key hints when set.
    public var notice: String?
    /// Where to go to act on the notice, shown as a link after it.
    public var noticeLink: URL?

    public init(store: HistoryStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        store.onChange = { [weak self] in self?.rebuild(keepingSelection: true) }
        rebuild(keepingSelection: false)
    }

    public var countLabel: String {
        let total = store.items.count
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(rows.count) of \(total)"
        }
        return total == 1 ? "1 item" : "\(total) items"
    }

    /// True when peeking would show something: in Presentation Mode, on
    /// a selected row with characters to peek at (not an image or a
    /// secret).
    public var selectionCanPeek: Bool {
        hidesContents && rows.first { $0.id == selectedID }?.presentation.peek != nil
    }

    /// Whether the selected row is a secret, which Cmd+S can keep as an
    /// ordinary item.
    public var selectionIsSecret: Bool {
        rows.first { $0.id == selectedID }?.expiresIn != nil
    }

    /// Cmd+S: keeps the selected secret as an ordinary item, which is
    /// saved, shown in full and stays selected. Works whatever the
    /// settings, so a wrong guess can be undone even after Secrets was
    /// turned off. Returns false when the selection is no secret.
    @discardableResult
    public func keepSelectedAsOrdinary() -> Bool {
        guard let selectedID, selectionIsSecret else { return false }
        pinnedID = selectedID
        store.keepAsOrdinary(selectedID)
        return true
    }

    public var selectedItem: ClipItem? {
        guard let selectedID, rows.contains(where: { $0.id == selectedID }) else { return nil }
        return store.items.first { $0.id == selectedID }
    }

    /// The item behind a visible row; nil for an id that is not visible.
    public func visibleItem(_ id: UUID) -> ClipItem? {
        guard rows.contains(where: { $0.id == id }) else { return nil }
        return store.items.first { $0.id == id }
    }

    /// Called each time the panel is shown.
    public func open() {
        notice = nil
        noticeLink = nil
        pinnedID = nil
        peeking = false
        query = ""
        rebuild(keepingSelection: false)
    }

    public func moveSelection(by delta: Int) {
        guard let current = rows.firstIndex(where: { $0.id == selectedID }) else {
            unpin()
            selectedID = rows.first?.id
            return
        }
        // The target is found among the rows as shown, before the row
        // Cmd+S changed leaves them.
        let target = rows[min(max(current + delta, 0), rows.count - 1)].id
        unpin()
        if rows.contains(where: { $0.id == target }) { selectedID = target }
    }

    /// The item Cmd+n pastes, counting within the visible (filtered) rows.
    public func item(quickNumber n: Int) -> ClipItem? {
        guard (1...9).contains(n), n <= rows.count else { return nil }
        let id = rows[n - 1].id
        return store.items.first { $0.id == id }
    }

    /// Selects a visible row, as clicking it does. An id that is not
    /// among the visible rows is ignored.
    public func select(_ id: UUID) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if id != selectedID { unpin() }
        selectedID = id
    }

    /// Lets go of the row Cmd+S changed: it leaves the list if it no
    /// longer matches the filter.
    private func unpin() {
        guard pinnedID != nil else { return }
        pinnedID = nil
        rebuild(keepingSelection: true)
    }

    public func deleteSelected() {
        pinnedID = nil
        guard let index = rows.firstIndex(where: { $0.id == selectedID }) else { return }
        let removed = rows[index].id
        if index + 1 < rows.count {
            selectedID = rows[index + 1].id
        } else if index > 0 {
            selectedID = rows[index - 1].id
        } else {
            selectedID = nil
        }
        store.remove(removed)
    }

    /// Brings ages and secrets' remaining times up to date.
    public func refreshTimes() {
        rebuild(keepingSelection: true)
    }

    public func escape() -> EscapeResult {
        if query.isEmpty { return .close }
        query = ""
        return .clearedQuery
    }

    /// Works the rows out again. With `keepingSelection` the selected
    /// row stays selected if it is still listed; if it is not, the row
    /// now in its place is selected, or with `elseFirst` the first row,
    /// as when the filter changes.
    private func rebuild(keepingSelection: Bool, elseFirst: Bool = false) {
        let items = store.items
        let liveIDs = Set(items.map(\.id))
        presentations = presentations.filter { liveIDs.contains($0.key) }

        let date = now()
        var built: [Row] = []
        for item in items {
            var presentation: RowPresentation
            if let cached = presentations[item.id], cached.isSecret == item.isSecret, cached.hidden == hidesContents {
                presentation = cached.row
            } else {
                presentation = RowPresentation(item, hidingContents: hidesContents, markerKey: Self.markerKey)
                presentations[item.id] = (item.isSecret, hidesContents, presentation)
            }
            if hidesContents, !presentation.sizedFiles.isEmpty {
                if let size = fileSizes[item.contentHash] {
                    if let size { presentation = presentation.withFileSize(size) }
                } else {
                    readFileSize(presentation.sizedFiles, hash: item.contentHash)
                }
            }
            guard presentation.matches(query) || item.id == pinnedID else { continue }
            built.append(Row(
                id: item.id,
                number: built.count < 9 ? built.count + 1 : nil,
                presentation: presentation,
                sourceApp: item.sourceApp ?? "",
                age: ageString(from: item.lastUsedAt, now: date),
                expiresIn: item.expiresAt.map { remainingString(until: $0, now: date) }
            ))
        }
        let oldIndex = rows.firstIndex { $0.id == selectedID }
        rows = built

        if keepingSelection, let selectedID, built.contains(where: { $0.id == selectedID }) {
            return
        }
        // The selected row went away by itself (a secret whose time ran
        // out): the row now in its place is selected, as after a delete,
        // so that Return does not paste the newest item instead. Not when
        // the mode changed the rows (`elseFirst`).
        if keepingSelection, !elseFirst, let oldIndex, !built.isEmpty {
            selectedID = built[min(oldIndex, built.count - 1)].id
            return
        }
        selectedID = built.first?.id
    }

    /// Size reads go one at a time on a queue of their own: one that
    /// hangs on a share that is gone holds up only the reads after it.
    private static let sizeQueue = DispatchQueue(label: "Klippari.fileSizes", qos: .utility)

    private func readFileSize(_ files: [URL], hash: String) {
        let generation = sizeGeneration
        let key = "\(generation) \(hash)"
        guard !sizesBeingRead.contains(key) else { return }
        sizesBeingRead.insert(key)
        Self.sizeQueue.async {
            let size = RowPresentation.totalSize(of: files)
            // Holds the model until the answer comes. One replaced by Try
            // Again or Reset Saved History then only rebuilds rows that
            // nothing shows.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sizesBeingRead.remove(key)
                    guard generation == self.sizeGeneration, self.hidesContents else { return }
                    self.fileSizes[hash] = .some(size)
                    guard !self.sizeRebuildPending else { return }
                    self.sizeRebuildPending = true
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.sizeRebuildPending = false
                            self.rebuild(keepingSelection: true)
                        }
                    }
                }
            }
        }
    }
}
