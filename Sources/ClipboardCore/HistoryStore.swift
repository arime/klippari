import CryptoKit
import Foundation
import os

/// The cleared history, which can be restored.
public struct ArchiveSummary: Equatable, Sendable {
    public var count: Int
    /// When the last clear was made.
    public var archivedAt: Date
    /// How many clears the items come from.
    public var clears: Int

    public init(count: Int, archivedAt: Date, clears: Int = 1) {
        self.count = count
        self.archivedAt = archivedAt
        self.clears = clears
    }
}

/// What a restore did.
public struct RestoreResult: Equatable, Sendable {
    /// How many items came back.
    public var restored: Int
    /// How many stayed in the archive because the history was full.
    public var noRoom: Int
    /// How many could not be moved back, and stay in the archive.
    public var failed: Int

    public init(restored: Int, noRoom: Int, failed: Int = 0) {
        self.restored = restored
        self.noRoom = noRoom
        self.failed = failed
    }

    /// What Settings says after the restore, so that one which left
    /// items behind never looks as if Restore did nothing. Nil when
    /// everything came back.
    public var note: String? {
        guard noRoom > 0 || failed > 0 else { return nil }
        if restored == 0, failed == 0 {
            return "The history is full, so nothing was restored. Raise Keep last to make room."
        }
        var note = restored == 0
            ? "Nothing was restored."
            : "Restored \(restored == 1 ? "1 item" : "\(restored) items")."
        if noRoom > 0 {
            note += " \(noRoom) did not fit: raise Keep last to restore them."
        }
        if failed > 0 {
            note += failed == 1
                ? " 1 could not be moved back and is still in the cleared history."
                : " \(failed) could not be moved back and are still in the cleared history."
        }
        return note
    }
}

/// The ordered history, newest first, mirrored to disk. Items in memory
/// carry lightened content (text and file URLs only); images and other
/// large data stay on disk until an item is pasted.
///
/// Secrets are the exception: they are never written to disk, keep their
/// full content in memory, and leave the history after `secretLifetime`.
@MainActor public final class HistoryStore {
    /// How long a secret stays in the history after it was copied.
    public static let secretLifetime: TimeInterval = 10 * 60
    /// How long each clear can be restored after it was made.
    public static let archiveLifetime: TimeInterval = 24 * 60 * 60
    /// The most the cleared history may take on disk, in bytes. Past
    /// it the oldest clears are deleted, though never the one just made.
    public var archiveSizeLimit: Int64 = 1_000_000_000

    private let storage: ItemStorage
    /// Where clearing the history moves it, so clearing can be
    /// undone: next to the storage (see `StorageLocation.archiveRoot`),
    /// with a folder for each clear.
    public let archiveRoot: URL
    private var archive: ClearedHistory { ClearedHistory(root: archiveRoot, cipher: storage.cipher) }
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "store")

    public private(set) var items: [ClipItem]

    /// Maximum number of items kept. Lowering it drops the oldest at once.
    public var limit: Int {
        didSet {
            trim()
            onChange?()
        }
    }

    /// Called after every mutation.
    public var onChange: (() -> Void)?
    /// Called when a secret joins the history, so its expiry can be
    /// timed; true when that took items out of the cleared history.
    /// With `scansClearedHistoryInBackground`, it is called again, with
    /// true, once the cleared history has been searched and copies were
    /// deleted.
    public var onSecretAdded: ((_ clearedHistoryChanged: Bool) -> Void)?
    /// Whether a new secret's copies are looked for in the cleared
    /// history off the main thread. That means opening every item in it,
    /// which is slow for a large one, and it happens in the clipboard
    /// poll. The app turns it on; tests leave it off, to see the result
    /// at once. Restore deletes copies of a secret in the history by
    /// itself, so it is safe while a search is under way.
    public var scansClearedHistoryInBackground = false
    /// Whether the user said this text is no secret (`keepAsOrdinary`):
    /// true while an ordinary item with its text and that mark is in the
    /// history. The mark lives in the item, saved in its manifest, so it
    /// goes when the item leaves the history (cleared, trimmed or
    /// deleted), and comes back with it on Restore.
    private func isMarkedNotSecret(_ key: String) -> Bool {
        items.contains { !$0.isSecret && $0.notSecret && Self.secretKey($0) == key }
    }

    /// The Secrets setting. Off by default: every copy is then saved, and
    /// nothing is taken for a secret. Turning it off leaves secrets
    /// already in the history to expire as usual.
    public var detectsSecrets = false
    /// The setting nested under Secrets, 'Always mask chosen texts'. Off
    /// by default. While it and `detectsSecrets` are on, Cmd+S in the
    /// panel can mask an ordinary row's text always (`maskAlways`) and
    /// new copies holding a text in `maskedTexts` are secrets. Off, the
    /// list is kept but not applied.
    public var masksChosenTexts = false

    /// Whether Cmd+S in the panel can mask an ordinary row's text
    /// always. Keeping a secret as an ordinary item works regardless.
    public var secretShortcutEnabled: Bool { detectsSecrets && masksChosenTexts }

    /// Where `maskedTexts` is kept, sealed (see `MaskedTexts`).
    private let maskedTextsURL: URL
    /// Texts to mask always: a new copy containing one is a secret.
    /// Added with `maskAlways` (Cmd+S on an ordinary row), removed by
    /// `keepAsOrdinary` (Cmd+S on a secret that holds one). Nothing
    /// lists them.
    public private(set) var maskedTexts: [String] = []

    /// With `sealingPlainItems`, history written before encryption is
    /// encrypted first (see `sealPlainHistory`). The app does that on
    /// its own, off the main thread, and passes false.
    public init(storage: ItemStorage, limit: Int = 50, sealingPlainItems: Bool = true) {
        self.storage = storage
        archiveRoot = StorageLocation.archiveRoot(forItems: storage.root)
        maskedTextsURL = MaskedTexts.url(forItems: storage.root)
        self.limit = limit
        if sealingPlainItems {
            Self.sealPlainHistory(storage)
        } else {
            Self.tidy(storage)
        }
        self.items = storage.loadAll()
        trim()
        // Saved items are never taken for secrets afterwards, at launch
        // or on Restore: only new copies are.
        maskedTexts = MaskedTexts.load(from: maskedTextsURL, cipher: storage.cipher)
    }

    private func saveMaskedTexts() {
        do {
            try MaskedTexts.save(maskedTexts, to: maskedTextsURL, cipher: storage.cipher)
        } catch {
            Self.logger.error("Could not save the masked texts: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Encrypts the history and the cleared history written before
    /// encryption. Loading skips whatever is not sealed, so this comes
    /// first. It reads and writes each such item in full, which takes a
    /// while for a large history, so it can run off the main thread.
    /// Returns whether nothing plain is left.
    @discardableResult
    nonisolated public static func sealPlainHistory(_ storage: ItemStorage) -> Bool {
        let archive = tidy(storage)
        // A clear's date is in its folder's name, so sealing its items
        // leaves when it expires unchanged.
        storage.sealPlainItems()
        for clear in archive.clears() {
            clear.storage.sealPlainItems()
        }
        return !ItemStorage.holdsPlainItems(in: [storage.root, archive.root])
    }

    /// Sorts a flat cleared history into a clear, dated by the folder's
    /// modification time (before anything rewrites items in it), and
    /// removes what interrupted saves left in the clears' folders.
    @discardableResult
    nonisolated private static func tidy(_ storage: ItemStorage) -> ClearedHistory {
        let archive = ClearedHistory(
            root: StorageLocation.archiveRoot(forItems: storage.root), cipher: storage.cipher
        )
        archive.adoptFlatLayout()
        for clear in archive.clears() {
            clear.storage.removeLeftovers()
        }
        return archive
    }

    /// Items on disk, in the history or the cleared history, that the
    /// key cannot open (see `ItemStorage.unreadableItems`). They are
    /// not loaded, so nothing else shows them.
    public func unreadableItems(countingPlain: Bool) -> [URL] {
        ItemStorage.unreadableItems(in: [storage.root, archiveRoot], cipher: storage.cipher, countingPlain: countingPlain)
    }

    /// Deletes what `unreadableItems` lists. Returns how many went.
    @discardableResult
    public func removeUnreadableItems(countingPlain: Bool) -> Int {
        var removed = 0
        for folder in unreadableItems(countingPlain: countingPlain)
        where (try? FileManager.default.removeItem(at: folder)) != nil {
            removed += 1
        }
        return removed
    }

    /// Records a copy. Content identical to an existing item moves that
    /// item to the top instead of adding a duplicate. A `secret` copy is
    /// kept in memory only, until `secretLifetime` from now. A copy with
    /// the same text as a secret in the history is that secret again,
    /// whatever app it came from.
    ///
    /// A secret by its content takes every copy with its text out of the
    /// history, off the disk and out of the cleared history: the same
    /// password copied from two apps usually comes with different other
    /// types, so the exact content rarely matches. A secret only by its
    /// source app leaves earlier copies alone, and a text the history
    /// already holds as an ordinary item is not taken for one at all: it
    /// was saved and shown in clear before, so it may be a user name.
    @discardableResult
    public func add(
        _ content: ClipContent, sourceApp: String?, secret reason: Secrets.Reason? = nil, now: Date
    ) -> ClipItem {
        let hash = content.contentHash
        let key = Self.secretKey(content, hash: hash)
        let live = items.first { $0.isSecret && Self.secretKey($0) == key }
        let marked = isMarkedNotSecret(key)
        var reason = marked ? nil : reason
        if reason == nil, !marked, let live {
            reason = live.secretByContent ? .content : .sourceApp
        }
        if reason == .sourceApp, live == nil,
           items.contains(where: { !$0.isSecret && Self.secretKey($0) == key }) {
            reason = nil
        }
        if let reason {
            let byContent = reason == .content || live?.secretByContent == true
            // A secret by content already in the history took the copies
            // out when it came, so a repeat copy opens nothing.
            let archiveChanged = byContent && live?.secretByContent != true
                ? deleteArchivedCopies(matching: key) : false
            let earlier = items.filter { Self.secretKey($0) == key }
            for old in earlier where !old.isSecret {
                storage.delete(id: old.id)
            }
            items.removeAll { Self.secretKey($0) == key }
            // The same content keeps its row; a fresh lifetime either way.
            let item = ClipItem(
                id: earlier.first(where: { $0.contentHash == hash })?.id ?? UUID(),
                capturedAt: now, lastUsedAt: now, sourceApp: sourceApp,
                content: content, imageInfo: ImageInfo.inspect(content), contentHash: hash,
                expiresAt: now.addingTimeInterval(Self.secretLifetime), secretByContent: byContent
            )
            items.insert(item, at: 0)
            onChange?()
            onSecretAdded?(archiveChanged)
            return item
        }
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            return touch(index, now: now)
        }

        var item = ClipItem(
            id: UUID(), capturedAt: now, lastUsedAt: now, sourceApp: sourceApp,
            content: content, imageInfo: ImageInfo.inspect(content), contentHash: hash,
            notSecret: marked
        )
        do {
            try storage.save(item)
            item.content = content.lightened
        } catch {
            // Keep the full content in memory, so the item can still be
            // pasted; it just will not survive a restart.
            Self.logger.error("Could not save item: \(error.localizedDescription, privacy: .public)")
        }
        items.insert(item, at: 0)
        trim()
        onChange?()
        return item
    }

    /// Takes over another store's items, as when the history moves from
    /// a folder kept for one run to the saved one. Each item is saved
    /// here with its full content, read from the other store; secrets
    /// stay in memory, with the time they have left, and leave this
    /// store's cleared history. Content already here is not added twice,
    /// and the history size applies. An item whose content can no longer
    /// be read whole is left out: it could not be pasted either.
    public func adopt(_ other: HistoryStore) {
        var archiveChanged = false
        // Marks from both histories: an item marked in either wins.
        let marked = Set((items + other.items).filter { !$0.isSecret && $0.notSecret }.map(Self.secretKey))
        let newTexts = other.maskedTexts.filter { text in
            !maskedTexts.contains { $0.caseInsensitiveCompare(text) == .orderedSame }
        }
        if !newTexts.isEmpty {
            maskedTexts += newTexts
            saveMaskedTexts()
        }
        // Secrets first, as `add` takes them: one by its content takes
        // every item with its text out of this history, off the disk and
        // out of the cleared history, even one already saved here. One by
        // its source app gives way to an ordinary item with its text here.
        for item in other.items where item.isSecret && item.content.isComplete {
            let key = Self.secretKey(item)
            guard item.secretByContent else {
                if !items.contains(where: { Self.secretKey($0) == key }) { items.append(item) }
                continue
            }
            // The user said this text is no secret, in a saved item the
            // other history could not know of: that mark wins.
            if marked.contains(key) { continue }
            for old in items where !old.isSecret && Self.secretKey(old) == key {
                storage.delete(id: old.id)
            }
            items.removeAll { Self.secretKey($0) == key }
            if deleteArchivedCopies(matching: key) { archiveChanged = true }
            items.append(item)
        }
        let present = Set(items.map(\.contentHash))
        // A secret by content here keeps its text off the disk, whatever
        // other types a copy from the other history came with.
        let contentSecrets = Set(items.filter { $0.isSecret && $0.secretByContent }.map(Self.secretKey))
        for var item in other.items where !item.isSecret && !present.contains(item.contentHash)
            && !contentSecrets.contains(Self.secretKey(item)) {
            let full = other.fullContent(for: item.id) ?? item.content
            guard full.isComplete else { continue }
            item.content = full
            do {
                try storage.save(item)
                item.content = full.lightened
            } catch {
                Self.logger.error("Could not save item: \(error.localizedDescription, privacy: .public)")
            }
            items.append(item)
        }
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
        trim()
        onChange?()
        if items.contains(where: \.isSecret) { onSecretAdded?(archiveChanged) }
    }

    /// Turns a secret into an ordinary item, saved like any other, for
    /// when the user says it is not a secret. Copies of the same text are
    /// not taken for secrets again while the item is in the history.
    /// Texts masked always that it holds are no longer masked, and a
    /// search of the cleared history for its text, if one is under way,
    /// no longer deletes what it finds (see `finishArchiveSearch`).
    public func keepAsOrdinary(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.isSecret }) else { return }
        var item = items[index]
        if let string = item.content.plainString {
            let before = maskedTexts.count
            maskedTexts.removeAll { Secrets.containsMaskedText(string, [$0]) }
            if maskedTexts.count != before { saveMaskedTexts() }
        }
        item.expiresAt = nil
        item.notSecret = true
        item.secretByContent = false
        do {
            try storage.save(item)
            item.content = item.content.lightened
        } catch {
            Self.logger.error("Could not save item: \(error.localizedDescription, privacy: .public)")
        }
        items[index] = item
        trim()
        onChange?()
    }

    /// Masks an ordinary item's text always, for Cmd+S on its row while
    /// Secrets is on: the text joins `maskedTexts`, so new copies holding
    /// it are secrets, and the item itself becomes one, taken off the
    /// disk and out of the cleared history, and gone `secretLifetime`
    /// from now. Other saved items that merely contain the text are left
    /// as they are. A text shorter than `MaskedTexts.shortestText` is
    /// refused. Returns whether the item became a secret.
    @discardableResult
    public func maskAlways(_ id: UUID, now: Date) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && !$0.isSecret }),
              let text = items[index].content.plainString?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= MaskedTexts.shortestText,
              let full = items[index].content.isComplete ? items[index].content : storage.loadContent(id: id),
              full.isComplete
        else { return false }
        var item = items[index]
        let key = Self.secretKey(item)
        if !Secrets.containsMaskedText(text, maskedTexts) {
            maskedTexts.append(text)
            saveMaskedTexts()
        }
        for old in items where Self.secretKey(old) == key && !old.isSecret {
            storage.delete(id: old.id)
        }
        items.removeAll { $0.id != id && Self.secretKey($0) == key }
        // Even a cleared copy marked as no secret goes: masking it always
        // is the user's later word.
        let archiveChanged = deleteArchivedCopies(matching: key, includingMarked: true)
        item.content = full
        item.notSecret = false
        item.secretByContent = true
        item.expiresAt = now.addingTimeInterval(Self.secretLifetime)
        if let at = items.firstIndex(where: { $0.id == id }) { items[at] = item }
        onChange?()
        onSecretAdded?(archiveChanged)
        return true
    }

    public func markUsed(_ id: UUID, now: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        touch(index, now: now)
    }

    /// When the next secret leaves the history; nil when there are none.
    public var nextSecretExpiry: Date? {
        items.lazy.compactMap(\.expiresAt).min()
    }

    /// Removes the secrets whose time is up. Returns whether any were.
    @discardableResult
    public func expireSecrets(now: Date) -> Bool {
        let before = items.count
        items.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
        guard items.count != before else { return false }
        onChange?()
        return true
    }

    /// The item's complete content for pasting. Falls back to what is in
    /// memory if the disk copy cannot be read.
    public func fullContent(for id: UUID) -> ClipContent? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if item.content.isComplete { return item.content }
        return storage.loadContent(id: id) ?? item.content
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        storage.delete(id: id)
        onChange?()
    }

    /// Clears the history by moving it to the archive, as a clear of its
    /// own beside those made before: an archived copy of something
    /// cleared again now gives way to the newer one. Secrets are dropped,
    /// never archived. Returns how many items were archived, which is
    /// how many can be restored. An item kept only in memory, because saving
    /// it failed, is saved into the archive. An item that could not be
    /// moved or saved stays in the history and is not counted; 0 means
    /// nothing can be restored, though secrets may have gone. If the archive has grown past
    /// `archiveSizeLimit`, the oldest clears are deleted.
    @discardableResult
    public func archiveAll(now: Date) -> Int {
        guard !items.isEmpty else { return 0 }
        let archive = archive
        let earlier = archive.items()
        let clear = archive.storage(for: now)
        var (moved, left) = storage.archive(items.lazy.filter { !$0.isSecret }.map(\.id), to: clear)
        // An item whose save failed is only in memory, with its full
        // content: save it into the archive instead. If that fails too,
        // it stays in the history. A secret is never written to disk.
        for item in items where !item.isSecret && !moved.contains(item.id) && !left.contains(item.id) {
            do {
                try clear.save(item)
                moved.insert(item.id)
            } catch {
                left.insert(item.id)
            }
        }
        if !left.isEmpty {
            Self.logger.error("Could not archive \(left.count) items")
        }

        let cleared = Set(items.filter { moved.contains($0.id) }.map(\.contentHash))
        for old in earlier where cleared.contains(old.item.contentHash) {
            // The same item moved into the same folder has replaced itself.
            if old.clear.storage.root.path == clear.root.path && moved.contains(old.item.id) { continue }
            old.clear.storage.delete(id: old.item.id)
        }
        archive.removeEmpty()
        archive.trim(toBytes: archiveSizeLimit, keeping: clear)

        // What was archived is gone from the history, so the list never
        // shows an item whose files have moved, and the count is only
        // of items that can be restored. Secrets go too, unarchived.
        let before = items.count
        let archived = items.filter { moved.contains($0.id) }.count
        items.removeAll { moved.contains($0.id) || $0.isSecret }
        guard items.count != before else { return 0 }
        onChange?()
        return archived
    }

    /// Texts of secrets whose copies are still being looked for in the
    /// cleared history, by `secretKey`, with how many searches are under
    /// way for each. Restore deletes their archived copies itself rather
    /// than restoring them, even once the secret has left the history.
    private var pendingArchiveSearches: [String: Int] = [:]
    /// Of those, the texts masked always by Cmd+S, whose search deletes
    /// copies marked as no secret too: the user's later word wins.
    private var pendingSearchesIncludingMarked: Set<String> = []

    /// Deletes every item in the cleared history that is the secret with
    /// this key, so that it cannot be restored from there as a saved
    /// item. A clear's date is in its folder's name, so its time left is
    /// kept. Opening the cleared history means decrypting every item in
    /// it, so nothing is opened when there is none. Returns whether any
    /// item was deleted; false at once with
    /// `scansClearedHistoryInBackground`, which reports through
    /// `onSecretAdded` instead.
    ///
    /// In the background only the reading happens off the main thread,
    /// and it deletes nothing, not even what an interrupted save left:
    /// a clear may be under way. The copies found are deleted back on
    /// the main actor, where every other change to the cleared history
    /// is made.
    ///
    /// Copies the user marked as no secret are left alone, unless
    /// `includingMarked`, for a text the user has since masked always.
    @discardableResult
    private func deleteArchivedCopies(matching key: String, includingMarked: Bool = false) -> Bool {
        let archive = archive
        guard !archive.clears().isEmpty else { return false }
        guard scansClearedHistoryInBackground else {
            return Self.deleteCopies(of: key, in: archive, includingMarked: includingMarked)
        }
        pendingArchiveSearches[key, default: 0] += 1
        if includingMarked { pendingSearchesIncludingMarked.insert(key) }
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                archive.items(tidying: false)
                    .filter { (includingMarked || !$0.item.notSecret) && Self.secretKey($0.item) == key }
                    .map { (storage: $0.clear.storage, id: $0.item.id) }
            }.value
            self?.finishArchiveSearch(for: key, deleting: found)
        }
        return false
    }

    private func finishArchiveSearch(for key: String, deleting found: [(storage: ItemStorage, id: UUID)]) {
        if let count = pendingArchiveSearches[key], count > 1 {
            pendingArchiveSearches[key] = count - 1
        } else {
            pendingArchiveSearches[key] = nil
            pendingSearchesIncludingMarked.remove(key)
        }
        // Cmd+S said 'not a secret' while the search ran.
        guard !found.isEmpty, !isMarkedNotSecret(key) else { return }
        for copy in found {
            copy.storage.delete(id: copy.id)
        }
        archive.removeEmpty()
        onSecretAdded?(true)
    }

    /// Finishes the searches still under way at once, on the main
    /// thread, so that quitting cannot leave a secret's copy in the
    /// cleared history to be restored after a relaunch.
    public func finishPendingArchiveSearches() {
        let keys = pendingArchiveSearches.keys
        let includingMarked = pendingSearchesIncludingMarked
        pendingArchiveSearches = [:]
        pendingSearchesIncludingMarked = []
        let archive = archive
        for key in keys where !isMarkedNotSecret(key) {
            Self.deleteCopies(of: key, in: archive, includingMarked: includingMarked.contains(key))
        }
    }

    @discardableResult
    nonisolated private static func deleteCopies(
        of key: String, in archive: ClearedHistory, includingMarked: Bool = false
    ) -> Bool {
        var deleted = false
        for old in archive.items() where (includingMarked || !old.item.notSecret) && secretKey(old.item) == key {
            old.clear.storage.delete(id: old.item.id)
            deleted = true
        }
        if deleted { archive.removeEmpty() }
        return deleted
    }

    /// What makes two copies the same secret: a hash of their text when
    /// they have any, else their exact content. The history keeps every
    /// item's text in memory, so this works for saved and archived items
    /// alike.
    nonisolated static func secretKey(_ content: ClipContent, hash: String) -> String {
        guard let string = content.plainString, !string.isEmpty else { return "content:" + hash }
        let digest = SHA256.hash(data: Data(string.utf8))
        return "text:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func secretKey(_ item: ClipItem) -> String {
        secretKey(item.content, hash: item.contentHash)
    }

    /// The archived history, if there is one.
    public var archiveSummary: ArchiveSummary? {
        archive.summary
    }

    /// When the oldest clear is due to be deleted; nil when nothing is
    /// cleared.
    public var nextArchiveExpiry: Date? {
        archive.nextExpiry(lifetime: Self.archiveLifetime)
    }

    /// The shortest wait before checking the cleared history again.
    public static let archiveRetryInterval: TimeInterval = 60

    /// When to next check the cleared history: when the oldest clear is
    /// due, but never sooner than `archiveRetryInterval` from `now`. A
    /// clear that is overdue because it could not be deleted is then
    /// tried again once a minute, rather than over and over at once.
    /// Nil when nothing is cleared.
    public func nextArchiveCheck(now: Date) -> Date? {
        nextArchiveExpiry.map { max($0, now.addingTimeInterval(Self.archiveRetryInterval)) }
    }

    /// Deletes the archive for good.
    public func deleteArchive() {
        try? FileManager.default.removeItem(at: archiveRoot)
    }

    /// Deletes each clear `archiveLifetime` after it was made. Returns
    /// whether any was deleted.
    @discardableResult
    public func expireArchive(now: Date) -> Bool {
        archive.expire(now: now, lifetime: Self.archiveLifetime)
    }

    /// Puts back as many archived items as the history has room for,
    /// newest first by when each was last used, merged with what was
    /// copied since. The rest stay in the archive, so a restore never
    /// deletes an item or pushes one out of the history. The only thing
    /// it removes from the archive besides what came back is a copy of
    /// something already in the history. An item that could not be
    /// moved stays there too, in its clear, to be restored later. A
    /// secret by its content in the history never comes back as a saved
    /// item: its archived copy is deleted instead, even if adding the
    /// secret could not delete it. An archived ordinary copy of a secret
    /// only by its source app comes back, and the secret gives way to it,
    /// as when it is copied while that item is in the history. Archived
    /// items are restored as they were saved, never taken for secrets.
    @discardableResult
    public func restoreArchive() -> RestoreResult {
        let archive = archive
        // Secrets are left out: one only by its source app gives way to
        // its archived copy, and so does one by content to a copy the
        // user marked as no secret. Other copies of a secret by content
        // are deleted below.
        var seen = Set(items.filter { !$0.isSecret }.map(\.contentHash))
        // An archived copy of a secret by content is deleted, not
        // restored, even when it came with other types than the secret did.
        // So is one whose search is still under way: its secret may have
        // left the history since.
        let secrets = Set(items.filter { $0.isSecret && $0.secretByContent }.map(Self.secretKey))
            .union(pendingArchiveSearches.keys.filter { !isMarkedNotSecret($0) })
        var waiting: [(item: ClipItem, clear: ClearedHistory.Clear)] = []
        // Newest first, so a second copy of the same content is the older.
        for old in archive.items() {
            let key = Self.secretKey(old.item)
            let isSecretCopy = secrets.contains(key)
                && (!old.item.notSecret || pendingSearchesIncludingMarked.contains(key))
            if !isSecretCopy, seen.insert(old.item.contentHash).inserted {
                waiting.append(old)
            } else {
                old.clear.storage.delete(id: old.item.id)
            }
        }

        // An item that cannot be moved leaves its room to the next one.
        // Secrets take no room: they are not counted toward the limit.
        let room = max(limit - items.lazy.filter { !$0.isSecret }.count, 0)
        var result = RestoreResult(restored: 0, noRoom: 0, failed: 0)
        var saved = 0
        for (item, clear) in waiting {
            guard saved < room else {
                result.noRoom += 1
                continue
            }
            do {
                try clear.storage.move(id: item.id, to: storage)
                let key = Self.secretKey(item)
                items.removeAll { $0.isSecret && Self.secretKey($0) == key }
                items.append(item)
                result.restored += 1
                saved += 1
            } catch {
                Self.logger.error("Could not restore item: \(error.localizedDescription, privacy: .public)")
                result.failed += 1
            }
        }
        archive.removeEmpty()
        if result.restored > 0 {
            items.sort { $0.lastUsedAt > $1.lastUsedAt }
            onChange?()
        }
        return result
    }

    /// Moves an item to the top. Only its manifest is rewritten; the data
    /// files, which can be large, are left alone. A secret has nothing on
    /// disk, and its lifetime does not restart when it is pasted.
    @discardableResult
    private func touch(_ index: Int, now: Date) -> ClipItem {
        var item = items.remove(at: index)
        item.lastUsedAt = now
        items.insert(item, at: 0)
        if !item.isSecret {
            do {
                try storage.updateManifest(item)
            } catch {
                Self.logger.error("Could not update item: \(error.localizedDescription, privacy: .public)")
            }
        }
        onChange?()
        return item
    }

    /// Drops the oldest saved items past `limit`. Secrets do not count
    /// toward it: they leave by themselves within minutes, and must not
    /// push a saved item out of the history for good.
    private func trim() {
        var excess = items.lazy.filter { !$0.isSecret }.count - max(limit, 0)
        var index = items.count - 1
        while excess > 0, index >= 0 {
            if !items[index].isSecret {
                storage.delete(id: items.remove(at: index).id)
                excess -= 1
            }
            index -= 1
        }
    }
}
