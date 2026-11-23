import Foundation
import Testing
import ClipboardCore

// Made-up credentials, built from pieces so that secret scanners never
// see anything that looks like a real one in the source.
let fakeAnthropicKey = "sk-ant-" + "api03-" + String(repeating: "x", count: 30) + "Q4fZ"
let otherAnthropicKey = "sk-ant-" + "api03-" + String(repeating: "x", count: 30) + "m81K"
let fakeOpenAIKey = "sk-" + "proj-" + "Ab3" + String(repeating: "x", count: 40) + "Zq9"
let fakeGitHubToken = "gh" + "p_" + String(repeating: "a", count: 32) + "WXYZ"
let fakeAWSKey = "AK" + "IA" + "ABCDEFGHIJKLMNOP"
let fakeSlackToken = "xo" + "xb-" + "1234567890-" + "abcdefghij"
let fakeJWT = "ey" + "J" + "hbGciOiJIUzI1NiJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0" + ".SflKxwRJSMeKKF2QT4fwpM"
let fakePrivateKey = ["-----BEGIN OPENSSH " + "PRIVATE KEY-----", "b3BlbnNzaC1rZXktdjEAAAAA", "-----END OPENSSH PRIVATE KEY-----"]
    .joined(separator: "\n")

@MainActor @Suite struct SecretHistoryTests {
    let root = temporaryRoot()

    func makeStore(limit: Int = 50) -> HistoryStore {
        HistoryStore(storage: ItemStorage(root: root, cipher: testCipher), limit: limit)
    }

    func itemsOnDisk() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).count
    }

    @Test func secretsStayInMemoryOnly() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(0))
        #expect(item.expiresAt == at(HistoryStore.secretLifetime))
        #expect(itemsOnDisk() == 0)
        #expect(store.fullContent(for: item.id) == text(fakeAnthropicKey))
        #expect(makeStore().items.isEmpty)
    }

    @Test func secretsLeaveAfterTenMinutes() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        #expect(!store.expireSecrets(now: at(599)))
        #expect(store.items.count == 2)
        #expect(store.expireSecrets(now: at(600)))
        #expect(store.items.map(\.content) == [text("plain")])
    }

    @Test func nextSecretExpiryIsTheSoonest() {
        let store = makeStore()
        #expect(store.nextSecretExpiry == nil)
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(100))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(50))
        #expect(store.nextSecretExpiry == at(650))
        store.expireSecrets(now: at(650))
        #expect(store.nextSecretExpiry == at(700))
        store.expireSecrets(now: at(700))
        #expect(store.nextSecretExpiry == nil)
    }

    @Test func pastingDoesNotExtendASecretButCopyingAgainDoes() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        store.markUsed(item.id, now: at(300))
        #expect(store.items[0].expiresAt == at(600))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(400))
        #expect(store.items.count == 1)
        #expect(store.items[0].expiresAt == at(1000))
    }

    @Test func copyingASavedItemAsASecretTakesItOffTheDisk() {
        let store = makeStore()
        store.add(text("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        #expect(itemsOnDisk() == 1)
        let item = store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(1))
        #expect(itemsOnDisk() == 0)
        #expect(item.isSecret)
        #expect(store.items.count == 1)
    }

    /// The same password as Notes copies it: plain text beside rich text.
    func richCopy(_ string: String) -> ClipContent {
        content(typed(TypeName.plainText, string), typed(TypeName.rtf, "{\\rtf1 \(string)}"))
    }

    @Test func aSecretTakesARichCopyOfItsTextOffTheDisk() {
        let store = makeStore()
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        store.add(text("other"), sourceApp: "Notes", now: at(1))
        #expect(itemsOnDisk() == 2)
        let item = store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(2))
        #expect(itemsOnDisk() == 1)
        #expect(store.items.map(\.id) == [item.id, store.items[1].id])
        #expect(store.items.map(\.isSecret) == [true, false])
        #expect(store.items[0].sourceApp == "Passwords")
    }

    @Test func aSecretTakesARichCopyOfItsTextOutOfTheClearedHistory() {
        let store = makeStore()
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        store.add(text("other"), sourceApp: "Notes", now: at(1))
        store.archiveAll(now: at(2))
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(3))
        #expect(store.archiveSummary?.count == 1)
        store.expireSecrets(now: at(1000))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("other")])
    }

    @Test func theSameTextFromAnyAppIsTheSecretAgain() {
        let store = makeStore()
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(0))
        let rich = store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(300))
        #expect(itemsOnDisk() == 0)
        #expect(store.items.count == 1)
        #expect(store.items[0].isSecret)
        #expect(store.items[0].expiresAt == at(900))
        // Copied again exactly, from an ordinary app: the same row, with a
        // fresh lifetime.
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(400))
        #expect(store.items.count == 1)
        #expect(store.items[0].expiresAt == at(1000))
        #expect(store.items[0].id == rich.id)
    }

    @Test func keepingASecretAsOrdinarySavesIt() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(0))
        store.keepAsOrdinary(item.id)
        #expect(store.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
        #expect(!store.expireSecrets(now: at(1000)))
        #expect(makeStore().items.map(\.content) == [text(fakeAnthropicKey)])
        // Copied again, it is not taken for a secret this run.
        store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(1001))
        #expect(store.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
    }

    @Test func addingASecretSaysWhetherTheClearedHistoryChanged() {
        let store = makeStore()
        var calls: [Bool] = []
        store.onSecretAdded = { calls.append($0) }
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(1))
        store.add(text("other"), sourceApp: "Notes", now: at(2))
        store.archiveAll(now: at(3))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(4))
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(5))
        #expect(calls == [false, false, true])
    }

    @Test func aSavedTokenStaysSavedAtLaunch() {
        let store = makeStore()
        // Saved before Secrets was turned on, or by an earlier build.
        store.add(text("export GH_TOKEN=\(fakeGitHubToken)"), sourceApp: "Terminal", now: at(0))
        store.add(text("plain"), sourceApp: nil, now: at(1))
        let reopened = makeStore()
        reopened.detectsSecrets = true
        #expect(reopened.items.map(\.isSecret) == [false, false])
        #expect(itemsOnDisk() == 2)
        #expect(reopened.nextSecretExpiry == nil)
    }

    @Test func notASecretHoldsAcrossRestarts() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(0))
        store.keepAsOrdinary(item.id)
        let reopened = makeStore()
        #expect(reopened.items.map(\.isSecret) == [false])
        #expect(reopened.items[0].notSecret)
        // Copied again, as plain text or with other types: still not a secret.
        reopened.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(1))
        reopened.add(richCopy(fakeAnthropicKey), sourceApp: "Notes", secret: .content, now: at(2))
        #expect(reopened.items.map(\.isSecret) == [false, false])
        #expect(makeStore().items.map(\.isSecret) == [false, false])
    }

    @Test func aClearedTokenIsRestoredAsItWasSaved() {
        let store = makeStore()
        store.detectsSecrets = true
        store.add(text(fakeGitHubToken), sourceApp: "Terminal", now: at(0))
        store.add(text("plain"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(2))
        #expect(store.restoreArchive() == RestoreResult(restored: 2, noRoom: 0))
        #expect(store.items.map(\.isSecret) == [false, false])
        #expect(itemsOnDisk() == 2)
    }

    @Test func aPasswordAppCopyOfASavedTextIsNotASecret() {
        let store = makeStore()
        let email = store.add(text("me@example.com"), sourceApp: "Mail", now: at(0))
        // The user name field in Passwords.
        let copy = store.add(text("me@example.com"), sourceApp: "Passwords", secret: .sourceApp, now: at(1))
        #expect(copy.id == email.id)
        #expect(store.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
    }

    @Test func aPasswordAppSecretLeavesItsClearedCopyAndGivesWayOnRestore() {
        let store = makeStore()
        var calls: [Bool] = []
        store.onSecretAdded = { calls.append($0) }
        store.add(text("me@example.com"), sourceApp: "Mail", now: at(0))
        store.archiveAll(now: at(1))
        store.add(text("me@example.com"), sourceApp: "Passwords", secret: .sourceApp, now: at(2))
        #expect(calls == [false])
        #expect(store.archiveSummary?.count == 1)
        #expect(store.restoreArchive() == RestoreResult(restored: 1, noRoom: 0))
        #expect(store.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
    }

    @Test func aPasswordAppSecretIsStillASecretWhenNew() {
        let store = makeStore()
        store.add(text("correct horse battery staple"), sourceApp: "Passwords", secret: .sourceApp, now: at(0))
        #expect(store.items.map(\.isSecret) == [true])
        #expect(!store.items[0].secretByContent)
        #expect(itemsOnDisk() == 0)
    }

    @Test func aRepeatCopyOfASecretOpensNoClearedHistory() {
        let store = makeStore()
        var calls: [Bool] = []
        store.onSecretAdded = { calls.append($0) }
        store.add(text(fakeGitHubToken), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(2))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(3))
        #expect(calls == [true, false])
        #expect(store.archiveSummary == nil)
    }

    @Test func theClearedHistoryCanBeSearchedInTheBackground() async throws {
        let store = makeStore()
        store.scansClearedHistoryInBackground = true
        var calls: [Bool] = []
        store.onSecretAdded = { calls.append($0) }
        store.add(text(fakeGitHubToken), sourceApp: nil, now: at(0))
        store.add(text("other"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(2))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(3))
        #expect(calls == [false])
        for _ in 0..<200 where calls.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls == [false, true])
        #expect(store.archiveSummary?.count == 1)
    }

    /// Waits for the background searches the store started, which end
    /// on the main actor.
    func waitForSearches(_ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func restoreDuringASearchDoesNotBringTheSecretBack() async throws {
        let store = makeStore()
        store.scansClearedHistoryInBackground = true
        store.add(text(fakeGitHubToken), sourceApp: nil, now: at(0))
        store.add(text("other"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(2))
        let secret = store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(3))
        // The secret leaves before the search is done.
        store.remove(secret.id)
        #expect(store.restoreArchive() == RestoreResult(restored: 1, noRoom: 0))
        #expect(store.items.map(\.content) == [text("other")])
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.items.map(\.content) == [text("other")])
        #expect(itemsOnDisk() == 1)
    }

    @Test func clearingDuringASearchKeepsWhatWasCleared() async throws {
        let store = makeStore()
        store.scansClearedHistoryInBackground = true
        var changed = 0
        store.onSecretAdded = { if $0 { changed += 1 } }
        store.add(text(fakeGitHubToken), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(2))
        for n in 0..<20 {
            store.add(text("item \(n)"), sourceApp: nil, now: at(3 + Double(n)))
        }
        // A second clear while the search is under way: the secret goes,
        // the twenty items are cleared, and none of them is lost.
        #expect(store.archiveAll(now: at(100)) == 20)
        try await waitForSearches { changed > 0 }
        #expect(changed == 1)
        #expect(store.archiveSummary?.count == 20)
        #expect(store.restoreArchive() == RestoreResult(restored: 20, noRoom: 0))
    }

    @Test func quittingFinishesTheSearches() {
        let store = makeStore()
        store.scansClearedHistoryInBackground = true
        store.add(text(fakeGitHubToken), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(2))
        store.finishPendingArchiveSearches()
        #expect(store.archiveSummary == nil)
        #expect(makeStore().restoreArchive() == RestoreResult(restored: 0, noRoom: 0))
    }

    @Test func takingOverASecretKeepsASavedNotASecretMark() {
        let store = makeStore()
        let saved = store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(0))
        store.keepAsOrdinary(saved.id)
        // A run that could not open the saved history took it for one.
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        unsaved.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: .content, now: at(1))
        let reopened = makeStore()
        reopened.adopt(unsaved)
        #expect(reopened.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
    }

    @Test func theMarkEndsWhenItsItemIsDeleted() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        store.keepAsOrdinary(item.id)
        store.remove(item.id)
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(1))
        #expect(store.items.map(\.isSecret) == [true])
        #expect(itemsOnDisk() == 0)
    }

    @Test func theMarkEndsWhenItsItemIsTrimmed() {
        let store = makeStore(limit: 1)
        let item = store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        store.keepAsOrdinary(item.id)
        store.add(text("newer"), sourceApp: nil, now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(2))
        #expect(store.items.map(\.isSecret) == [true, false])
    }

    @Test func aClearedMarkedCopyIsKeptAndComesBackMarked() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        store.keepAsOrdinary(item.id)
        store.archiveAll(now: at(1))
        // After a relaunch the same text is a secret again, but the copy
        // the user marked stays in the cleared history.
        let reopened = makeStore()
        reopened.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(2))
        #expect(reopened.archiveSummary?.count == 1)
        // Restored, it brings its mark back, and the secret gives way.
        #expect(reopened.restoreArchive() == RestoreResult(restored: 1, noRoom: 0))
        #expect(reopened.items.map(\.isSecret) == [false])
        #expect(reopened.items[0].notSecret)
    }

    /// A cleared rich copy of a token, then the token as a secret with
    /// the search under way, which Cmd+S 'not a secret' must stop.
    func storeSearchingForAKeptToken() -> HistoryStore {
        let store = makeStore()
        store.scansClearedHistoryInBackground = true
        store.add(richCopy(fakeGitHubToken), sourceApp: "Notes", now: at(0))
        store.archiveAll(now: at(1))
        let secret = store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(2))
        store.keepAsOrdinary(secret.id)
        return store
    }

    @Test func notASecretDuringASearchStopsItsDeletions() async throws {
        let store = storeSearchingForAKeptToken()
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.archiveSummary?.count == 1)
        #expect(store.restoreArchive() == RestoreResult(restored: 1, noRoom: 0))
        #expect(store.items.map(\.isSecret) == [false, false])
    }

    @Test func notASecretBeforeQuittingStopsItsDeletions() {
        let store = storeSearchingForAKeptToken()
        store.finishPendingArchiveSearches()
        #expect(store.archiveSummary?.count == 1)
    }

    @Test func takingOverASecretSearchesTheClearedHistoryInTheBackground() async throws {
        let store = makeStore()
        store.scansClearedHistoryInBackground = true
        var changed = false
        store.onSecretAdded = { if $0 { changed = true } }
        store.add(text(fakeGitHubToken), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        unsaved.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(2))
        store.adopt(unsaved)
        // Restore while the search runs still leaves the copy out.
        #expect(store.restoreArchive() == RestoreResult(restored: 0, noRoom: 0))
        try await waitForSearches { changed || store.archiveSummary == nil }
        #expect(store.archiveSummary == nil)
        #expect(store.items.map(\.isSecret) == [true])
    }

    @Test func takingOverARichCopyOfASecretHereLeavesItOut() {
        let store = makeStore()
        store.add(text("hunter2-but-longer"), sourceApp: nil, secret: .content, now: at(0))
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        unsaved.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(1))
        store.adopt(unsaved)
        #expect(store.items.map(\.isSecret) == [true])
        #expect(itemsOnDisk() == 0)
    }

    @Test func clearingDropsSecretsAndArchivesTheRest() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(1))
        // Only what can be restored is counted.
        #expect(store.archiveAll(now: at(2)) == 1)
        #expect(store.items.isEmpty)
        #expect(store.archiveSummary?.count == 1)
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("plain")])
    }

    @Test func secretsDoNotPushSavedItemsOut() {
        let store = makeStore(limit: 2)
        store.add(text("oldest"), sourceApp: nil, now: at(0))
        store.add(text("newer"), sourceApp: nil, now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(2))
        store.add(text(otherAnthropicKey), sourceApp: nil, secret: .content, now: at(3))
        #expect(store.items.count == 4)
        #expect(itemsOnDisk() == 2)
        store.expireSecrets(now: at(1000))
        #expect(store.items.map(\.content) == [text("newer"), text("oldest")])
        // A saved copy past the limit still drops the oldest saved item.
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: .content, now: at(1001))
        store.add(text("newest"), sourceApp: nil, now: at(1002))
        #expect(store.items.map(\.content) == [text("newest"), text(fakeGitHubToken), text("newer")])
    }

    @Test func restoreLeavesSecretsOutOfItsRoom() {
        let store = makeStore(limit: 2)
        store.add(text("a"), sourceApp: nil, now: at(0))
        store.add(text("b"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(2))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(3))
        #expect(store.restoreArchive() == RestoreResult(restored: 2, noRoom: 0))
        #expect(store.items.count == 3)
    }

    @Test func clearingOnlySecretsKeepsThePreviousArchive() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(2))
        #expect(store.archiveAll(now: at(3)) == 0)
        #expect(store.items.isEmpty)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(1)))
    }

    /// Ari's reproduction: the cleared copy of a password must not come
    /// back once the secret it became has expired.
    @Test func aClearedCopyOfASecretCannotBeRestored() {
        let store = makeStore()
        let password = "correct horse battery staple"
        store.add(text(password), sourceApp: "Notes", now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(password), sourceApp: "Passwords", secret: .content, now: at(2))
        #expect(store.archiveSummary == nil)
        store.expireSecrets(now: at(2 + HistoryStore.secretLifetime))
        #expect(store.items.isEmpty)
        #expect(store.restoreArchive().restored == 0)
        #expect(store.items.isEmpty)
        #expect(itemsOnDisk() == 0)
    }

    @Test func aSecretLeavesTheClearedHistoryAndTheRestStays() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(2))
        // The clear keeps its date, and so its time left.
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(1)))
        store.expireSecrets(now: at(2 + HistoryStore.secretLifetime))
        #expect(store.restoreArchive().restored == 1)
        #expect(store.items.map(\.content) == [text("plain")])
    }

    @Test func restoreDeletesTheArchivedCopyOfASecretInMemory() {
        let password = "correct horse battery staple"
        let store = makeStore()
        store.add(text(password), sourceApp: "Passwords", secret: .content, now: at(0))
        // A copy reaches the cleared history after the secret was added,
        // here through another store on the same folder.
        let other = makeStore()
        other.add(text(password), sourceApp: "Notes", now: at(1))
        other.archiveAll(now: at(2))
        #expect(store.archiveSummary?.count == 1)

        #expect(store.restoreArchive().restored == 0)
        #expect(store.items.count == 1)
        #expect(store.items[0].isSecret)
        #expect(store.archiveSummary == nil)
        #expect(itemsOnDisk() == 0)
    }

    @Test func takingOverASecretDeletesItsClearedCopy() {
        let password = "correct horse battery staple"
        let store = makeStore()
        store.add(text(password), sourceApp: "Notes", now: at(0))
        store.archiveAll(now: at(1))
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        unsaved.add(text(password), sourceApp: "Passwords", secret: .content, now: at(2))
        store.adopt(unsaved)
        #expect(store.items.map(\.isSecret) == [true])
        #expect(store.archiveSummary == nil)
    }

    @Test func takingOverASecretTakesTheSavedCopyOffTheDisk() {
        let store = makeStore()
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        store.add(text("other"), sourceApp: "Notes", now: at(1))
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        unsaved.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: .content, now: at(2))
        store.adopt(unsaved)
        #expect(itemsOnDisk() == 1)
        #expect(store.items.map(\.isSecret) == [true, false])
        #expect(makeStore().items.map(\.content) == [text("other")])
    }

    @Test func secretsHaveNoThumbnail() {
        let store = makeStore()
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 20, height: 20)))
        let item = store.add(png, sourceApp: nil, secret: .content, now: at(0))
        // The panel and the preview read thumbnails from the storage.
        #expect(ItemStorage(root: root, cipher: testCipher).thumbnail(for: item.id) == nil)
    }
}

@MainActor @Suite struct SecretRowDetailTests {
    func row(_ content: ClipContent) -> RowPresentation {
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        return RowPresentation(store.add(content, sourceApp: nil, secret: .content, now: at(0)))
    }

    @Test func aSecretRowShowsNothingButItsMaskedLine() {
        let link = row(text("https://user:hunter2@example.com/"))
        #expect(link.kind == .text)
        #expect(link.title == "https://user:" + Secrets.dots + " " + Secrets.dots)
        #expect(link.tag == nil)
        let lines = row(text("# deploy\nexport GH_TOKEN=\(fakeGitHubToken)\n"))
        #expect(lines.tag == nil)
        #expect(lines.title == Secrets.dots)
        let file = row(content(typed(TypeName.fileURL, "file:///Users/me/passwords.csv")))
        #expect(file.kind == .text)
        #expect(file.title == Secrets.dots)
        #expect(!file.searchText.contains("passwords"))
        let styled = row(content(typed(TypeName.plainText, "hunter2-but-longer"), typed(TypeName.rtf, "{rtf}")))
        #expect(styled.tag == nil)
    }

    @Test func voiceOverReadsTheDotsAsHidden() {
        #expect(row(text(fakeAnthropicKey)).spokenTitle == "sk-ant- hidden Q4fZ")
        #expect(row(text("hunter2-but-longer")).spokenTitle == "hidden")
    }
}

@Suite struct SecretDetectionTests {
    @Test func knownCredentialFormats() {
        for credential in [fakeAnthropicKey, fakeOpenAIKey, fakeGitHubToken, fakeAWSKey, fakeSlackToken, fakeJWT] {
            #expect(Secrets.isMostlyCredential(credential), "\(credential.prefix(8))")
            #expect(Secrets.isMostlyCredential("export KEY=\(credential)\n"), "\(credential.prefix(8))")
        }
        #expect(Secrets.isMostlyCredential(fakePrivateKey))
    }

    @Test func moreCredentialFormats() {
        let x = { (n: Int) in String(repeating: "x", count: n) }
        let credentials: [String] = [
            "sk_" + "live_" + "Ab3" + x(24), // Stripe
            "rk_" + "test_" + "Ab3" + x(24),
            "gl" + "pat-" + x(20), // GitLab
            "AI" + "za" + x(35), // Google
            "np" + "m_" + x(36),
            "h" + "f_" + x(34), // Hugging Face
            "S" + "G." + x(22) + "." + x(43), // SendGrid
            "AGE-SECRET-" + "KEY-1" + String(repeating: "Q", count: 58),
            "aws_secret_" + "access_key = " + String(repeating: "aB3/", count: 10),
            "xa" + "pp-" + "1-A0123-" + x(10), // Slack app token
            "Authorization: Bearer " + x(30),
            "https://deploy:" + "hunter2-but-longer" + "@example.com/repo.git",
            "github_" + "pat_" + x(22),
            "gh" + "o_" + x(36), "gh" + "u_" + x(36), "gh" + "s_" + x(36), "gh" + "r_" + x(36),
            "AS" + "IA" + String(repeating: "Q", count: 16),
            "export AWS_SECRET_" + "ACCESS_KEY=" + String(repeating: "aB3/", count: 10),
            "Aws_Secret_" + "Access_Key: " + String(repeating: "aB3/", count: 10),
            "AWS_SESSION_" + "TOKEN=" + String(repeating: "IQoJb3JpZ2luX2Vj", count: 7),
        ]
        for credential in credentials {
            #expect(Secrets.isMostlyCredential(credential), "\(credential.prefix(10))")
        }
    }

    @Test func aPasswordInAURLShowsNoneOfItsCharacters() {
        let masked = Secrets.mask("https://deploy:" + "hunter2-but-longer" + "@example.com/repo.git")
        #expect(masked == "https://deploy:" + Secrets.dots + " " + Secrets.dots)
        let stripe = Secrets.mask("sk_" + "live_" + "Ab3" + String(repeating: "x", count: 21) + "Wq7Z")
        #expect(stripe == "sk_live_" + Secrets.dots + "Wq7Z")
    }

    @Test func ordinaryTextIsNotASecret() {
        let ordinary: [String] = [
            "Meeting notes: Q4 planning",
            UUID().uuidString,
            String(repeating: "3f9a", count: 16), // a SHA-256 in hex
            "https://example.com/path?q=1",
            "risk-assessment-document-final", // 'sk-' inside a word
            "https://shop.example/sk-hynix-platinum-p41-2tb-ssd", // a slug
            "<div class=\"sk-loading-spinner-container-wide\">", // a CSS class
            "sk-" + String(repeating: "abc1", count: 10), // no capitals
            "ssh://git@github.com/org/repo.git", // a user, no password
            "git@github.com:org/repo.git",
            "Bearer tokens expire after an hour.",
            "AKIA is how AWS key IDs start",
            "git rebase --onto main feature~3 feature",
        ]
        for string in ordinary {
            #expect(!Secrets.isMostlyCredential(string), "\(string)")
        }
    }

    @Test func passwordAppsMakeAnyCopyASecret() {
        let password = text("correct horse battery staple")
        #expect(Secrets.reason(for: password, frontmostBundleID: "com.apple.keychainaccess") == .sourceApp)
        #expect(Secrets.reason(for: password, frontmostBundleID: "com.apple.Passwords") == .sourceApp)
        #expect(Secrets.reason(for: password, frontmostBundleID: "com.apple.Notes") == nil)
        #expect(Secrets.reason(for: password, frontmostBundleID: nil) == nil)
        #expect(Secrets.reason(for: password, frontmostBundleID: nil, passwordAppWasFrontmost: true) == .sourceApp)
    }

    @Test func theCopysOwnSourceWinsOverTheFrontmostApp() {
        let marked = content(
            typed(TypeName.plainText, "correct horse battery staple"),
            typed(Secrets.sourceType, "com.bitwarden.desktop")
        )
        #expect(Secrets.reason(for: marked, frontmostBundleID: "com.apple.Notes") == .sourceApp)
        let fromNotes = content(
            typed(TypeName.plainText, "correct horse battery staple"),
            typed(Secrets.sourceType, "com.apple.Notes")
        )
        #expect(Secrets.reason(for: fromNotes, frontmostBundleID: "com.apple.keychainaccess") == nil)
    }

    @Test func aCopyThatIsMostlyACredentialIsASecret() {
        for string in [
            "token: \(fakeGitHubToken)",
            "  export GH_TOKEN=\(fakeGitHubToken)\n",
            "postgres://app:s3cret-pass@db.internal:5432/app",
            "curl -H 'Authorization: Bearer \(fakeJWT)' https://api.example.com/v1/me",
            fakePrivateKey,
            fakePrivateKey + "\n",
        ] as [String] {
            #expect(Secrets.reason(for: text(string), frontmostBundleID: nil) == .content, "\(string.prefix(12))")
        }
    }

    @Test func aLongTokenOnItsOwnIsASecret() {
        let longJWT = "ey" + "J" + String(repeating: "a", count: 300) + "." + String(repeating: "b", count: 600)
            + "." + String(repeating: "c", count: 300)
        for string in [
            longJWT,
            "Authorization: Bearer \(longJWT)",
            "curl -H 'Authorization: Bearer \(longJWT)' https://api.example.com/v1/me",
            "\(fakeAWSKey)\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "\(fakeGitHubToken)\n\n\(fakeAnthropicKey)\n",
        ] as [String] {
            #expect(Secrets.reason(for: text(string), frontmostBundleID: nil) == .content, "\(string.prefix(12))")
        }
    }

    @Test func commentsHeadersAndCertificatesAroundAKeyAreFine() {
        let certificate = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----"
        for string in [
            "[default]\naws_access_key_id = \(fakeAWSKey)\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "# prod token\nexport GH_TOKEN=\(fakeGitHubToken)",
            "// staging\n\(fakeAnthropicKey)",
            "; staging\n\(fakeAnthropicKey)",
            certificate + "\n" + fakePrivateKey,
            fakePrivateKey.replacingOccurrences(of: "\n", with: " "),
            "# export GH_TOKEN=\(fakeGitHubToken)",
            "// \(fakeAnthropicKey) (old)",
            ";\(fakeGitHubToken)",
            "#\(fakeGitHubToken)",
            "[\(fakeGitHubToken)]",
            "[profile temp]\naws_access_key_id = \(fakeAWSKey)\n"
                + "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
                + "aws_session_token = " + String(repeating: "IQoJb3JpZ2luX2Vj", count: 10),
        ] as [String] {
            #expect(Secrets.reason(for: text(string), frontmostBundleID: nil) == .content, "\(string.prefix(12))")
        }
    }

    @Test func aBareAWSSecretKeyOrALoneKeyHeaderIsNot() {
        for string in [
            "\(fakeAWSKey)\nwJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "-----BEGIN RSA " + "PRIVATE KEY-----",
            "# just a comment",
            "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----",
        ] as [String] {
            #expect(Secrets.reason(for: text(string), frontmostBundleID: nil) == nil, "\(string.prefix(12))")
        }
    }

    @Test func aLongerTextThatMerelyHoldsACredentialIsNot() {
        for string in [
            "services:\n  db:\n    environment:\n      DATABASE_URL: postgres://postgres:postgres@localhost/db\n",
            "12:00:01 GET /v1/me 200\n12:00:02 auth \(fakeJWT) ok\n",
            "Example key ID: \(fakeAWSKey)\nSee the IAM docs for more.",
            "Notes\n" + fakePrivateKey,
            String(repeating: "log ", count: 70) + fakeGitHubToken,
            "12:00:01 " + String(repeating: "x", count: 250) + " " + fakeJWT,
            Array(repeating: "export GH_TOKEN=\(fakeGitHubToken)", count: 6).joined(separator: "\n"),
        ] as [String] {
            #expect(Secrets.reason(for: text(string), frontmostBundleID: nil) == nil, "\(string.prefix(12))")
        }
    }

}

@Suite struct SecretMaskTests {
    @Test func credentialKeepsItsPrefixAndLastFour() {
        #expect(Secrets.mask(fakeAnthropicKey) == "sk-ant-" + Secrets.dots + "Q4fZ")
        #expect(Secrets.mask(fakeGitHubToken) == "ghp_" + Secrets.dots + "WXYZ")
        #expect(Secrets.mask(fakeAWSKey) == "AKIA" + Secrets.dots + "MNOP")
    }

    @Test func twoKeysOfOneKindCanBeToldApart() {
        #expect(Secrets.mask(fakeAnthropicKey) != Secrets.mask(otherAnthropicKey))
    }

    @Test func aVariableNameBeforeTheCredentialStays() {
        #expect(Secrets.mask("export GH_TOKEN=\(fakeGitHubToken)") == "export GH_TOKEN=ghp_" + Secrets.dots + "WXYZ")
        #expect(Secrets.mask("api_key: \"\(fakeAnthropicKey)\";") == "api_key: \"sk-ant-" + Secrets.dots + "Q4fZ\";")
    }

    @Test func otherTextBesideTheCredentialIsHidden() {
        // An AWS key ID is usually followed by its secret key.
        #expect(Secrets.mask("\(fakeAWSKey) wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
            == "AKIA" + Secrets.dots + "MNOP " + Secrets.dots)
        #expect(Secrets.mask("export GH_TOKEN=\(fakeGitHubToken) DB_PASSWORD=hunter2")
            == "export GH_TOKEN=ghp_" + Secrets.dots + "WXYZ " + Secrets.dots)
        #expect(Secrets.mask("password=hunter2 token=\(fakeGitHubToken)")
            == Secrets.dots + " ghp_" + Secrets.dots + "WXYZ")
    }

    @Test func privateKeyHeaderStaysButAOneLineKeyDoesNot() {
        #expect(Secrets.mask("-----BEGIN OPENSSH PRIVATE KEY-----") == "-----BEGIN OPENSSH PRIVATE KEY-----")
        let oneLine = fakePrivateKey.replacingOccurrences(of: "\n", with: " ")
        #expect(Secrets.isMostlyCredential(oneLine))
        #expect(!Secrets.mask(oneLine).contains("b3BlbnNzaC1rZXktdjEAAAAA"))
    }

    @Test func pgpPrivateKeyIsASecret() {
        let body = "\nVersion: GnuPG v2\n\nlQOYBF8xYzABCADc3Rk5Qm\n=Ab12"
        #expect(Secrets.isMostlyCredential("-----BEGIN PGP " + "PRIVATE KEY BLOCK-----" + body
            + "\n-----END PGP PRIVATE KEY BLOCK-----"))
        #expect(!Secrets.isMostlyCredential("-----BEGIN PGP PUBLIC KEY BLOCK-----" + body
            + "\n-----END PGP PUBLIC KEY BLOCK-----"))
    }

    @Test func aPrivateKeyCutShortIsASecret() {
        let header = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
        let body = "\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\nAAAAAAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5"
        for string in [
            header + body,
            header + body + "\n",
            header + "\nb3BlbnNzaC1rZXktdjEAAAAA",
            "-----BEGIN RSA " + "PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,0123\n\nMIIEpAIBAAKCAQEAx7",
            "-----BEGIN PGP " + "PRIVATE KEY BLOCK-----\n\nlQOYBF8xYzABCADc3Rk5Qm",
            "# deploy key\n" + header + body,
            "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----\n" + header + body,
            header + body + "\n-----END OPENSSH PRIVATE KEY----", // a dash short
            header + body + "\n-----END OPENSSH PRIVATE KE",
            header + body + "\n-----",
            (header + body).replacingOccurrences(of: "\n", with: "\r\n") + "\r\n",
        ] as [String] {
            #expect(Secrets.isMostlyCredential(string), "\(string.suffix(12))")
        }
        for string in [
            header,
            header + "\n",
            header + "\nb3Bl", // too little of a key to tell
            header + "\nThe key goes here.",
            header + "\n...",
            header + body + "\nSee the docs for more.",
            "Paste your key:\n" + header + body,
            "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOC",
        ] as [String] {
            #expect(!Secrets.isMostlyCredential(string), "\(string.suffix(12))")
        }
        // Its row shows the BEGIN line and dots, none of the key.
        #expect(Secrets.mask(header) == header)
        #expect(Secrets.mask("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ") == Secrets.dots)
    }

    @Test func everyKindOfLineBreakSeparatesLines() {
        let token = "export GH_TOKEN=\(fakeGitHubToken)"
        for separator in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let five = Array(repeating: token, count: 5).joined(separator: separator)
            #expect(Secrets.isMostlyCredential(five), "\(separator.unicodeScalars.map(\.value))")
            #expect(!Secrets.isMostlyCredential(five + separator + token), "\(separator.unicodeScalars.map(\.value))")
            #expect(!Secrets.isMostlyCredential("page one" + separator + token), "\(separator.unicodeScalars.map(\.value))")
        }
    }

    @Test func linesAreCountedPastCommentsAndHeaders() {
        let token = "export GH_TOKEN=\(fakeGitHubToken)"
        let comments = Array(repeating: "# a note", count: 50).joined(separator: "\n")
        // Five tokens under any number of comments are a secret; a sixth
        // line, even a comment holding a token, makes a longer text.
        let five = Array(repeating: token, count: 5).joined(separator: "\n")
        #expect(Secrets.isMostlyCredential(comments + "\n" + five))
        #expect(!Secrets.isMostlyCredential(comments + "\n" + five + "\n# " + token))
        #expect(!Secrets.isMostlyCredential(five + "\nplain"))
        // A large source file is not a secret.
        let source = Array(repeating: "let x = 1 // \(fakeGitHubToken)", count: 10_000).joined(separator: "\n")
        #expect(!Secrets.isMostlyCredential(source))
    }

    @Test func passwordsShowNothing() {
        #expect(Secrets.mask("hunter2") == Secrets.dots)
        #expect(Secrets.mask("correct horse battery staple") == Secrets.dots)
        #expect(Secrets.mask("sixteen-chars-pw") == Secrets.dots)
    }

    @Test func aPasswordRowShowsAndSearchesNoneOfIt() {
        var item = makeItem(text("correct horse battery staple"))
        item.expiresAt = at(600)
        let row = RowPresentation(item)
        #expect(row.title == Secrets.dots)
        #expect(!row.matches("cor"))
        #expect(!row.matches("ple"))
        #expect(row.matches("secret"))
    }
}

@MainActor @Suite struct SecretRowTests {
    @Test func rowIsMaskedAndSearchesOnlyWhatShows() {
        var item = makeItem(text(fakeAnthropicKey))
        item.expiresAt = at(600)
        let row = RowPresentation(item)
        #expect(row.title == "sk-ant-" + Secrets.dots + "Q4fZ")
        #expect(row.matches("q4fz"))
        #expect(row.matches("secret"))
        #expect(!row.matches("xxxxxxxx"))
        #expect(!row.matches("api03"))
    }

    @Test func copyingAgainAsASecretMasksTheRowAlreadyShown() {
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        let model = PanelModel(store: store, now: { at(2) })
        let password = "correct horse battery staple"
        let plain = store.add(text(password), sourceApp: "Terminal", now: at(0))
        #expect(model.rows.map(\.presentation.title) == [password])

        // The same text again, this time with a password app in front.
        let secret = store.add(text(password), sourceApp: "Keychain Access", secret: .content, now: at(1))
        #expect(secret.id == plain.id)
        #expect(model.rows.count == 1)
        #expect(model.rows[0].presentation.title == Secrets.dots)
        #expect(!model.rows[0].presentation.searchText.contains("correct"))
        #expect(model.rows[0].expiresIn != nil)
        model.query = "horse"
        #expect(model.rows.isEmpty)
    }

    @Test func panelShowsTimeLeft() {
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: .content, now: at(0))
        let model = PanelModel(store: store, now: { at(61) })
        model.open()
        #expect(model.rows.map(\.expiresIn) == ["9 min", nil])
    }

    @Test func remainingTimeRoundsUp() {
        #expect(remainingString(until: at(600), now: at(0)) == "10 min")
        #expect(remainingString(until: at(600), now: at(541)) == "1 min")
        #expect(remainingString(until: at(600), now: at(599)) == "1 min")
    }
}

/// The app in front, which a test changes as the user switches apps. On
/// the main actor, so the monitor's closures can read it while the test
/// changes it.
@MainActor final class FrontmostApp {
    private(set) var app: SourceApp

    init(_ name: String, _ bundleID: String) {
        app = SourceApp(name: name, bundleID: bundleID)
    }

    /// Brings another app to the front and tells the monitor, as the
    /// workspace's activation notification does.
    func switchTo(_ name: String, _ bundleID: String, monitor: ClipboardMonitor) {
        app = SourceApp(name: name, bundleID: bundleID)
        monitor.appDidActivate(app)
    }
}

@MainActor @Suite struct SecretMonitorTests {
    let pasteboard = FakePasteboard()
    let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))

    func makeMonitor(_ front: FrontmostApp, detecting: Bool = true) -> ClipboardMonitor {
        store.detectsSecrets = detecting
        return ClipboardMonitor(
            pasteboard: pasteboard, store: store,
            sourceApp: { front.app.name }, sourceBundleID: { front.app.bundleID }, now: { at(0) }
        )
    }

    @Test func aSecretIsPastedMarkedAsConcealed() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        let styled = content(typed(TypeName.plainText, "hunter2-but-longer"), typed(TypeName.rtf, "{rtf}"))
        pasteboard.copy(styled)
        monitor.tick()
        monitor.paste(store.items[0], plainText: false)
        monitor.paste(store.items[0], plainText: true)
        front.switchTo("Notes", "com.apple.Notes", monitor: monitor)
        monitor.tick()
        pasteboard.copy(text("plain"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
        monitor.paste(store.items[0], plainText: false)
        #expect(pasteboard.written == [
            styled.marked(TypeName.concealed),
            text("hunter2-but-longer").marked(TypeName.concealed),
            text("plain"),
        ])
    }

    @Test func monitorMarksCopiesFromPasswordApps() {
        let front = FrontmostApp("Keychain Access", "com.apple.keychainaccess")
        let monitor = makeMonitor(front)
        pasteboard.copy(text("correct horse battery staple"))
        monitor.tick()
        front.switchTo("Notes", "com.apple.Notes", monitor: monitor)
        monitor.tick()
        pasteboard.copy(text("shopping list"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
        #expect(store.items.map(\.sourceApp) == ["Notes", "Keychain Access"])
    }

    @Test func aPasswordCopiedJustBeforeSwitchingAwayIsASecret() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        pasteboard.copy(text("correct horse battery staple"))
        // Cmd+Tab before the next poll.
        front.switchTo("Safari", "com.apple.Safari", monitor: monitor)
        monitor.tick()
        #expect(store.items.count == 1)
        #expect(store.items[0].isSecret)
        #expect(store.items[0].sourceApp == "Passwords")
    }

    @Test func aCopySeenOnlyAfterLeavingAPasswordAppIsASecret() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        front.switchTo("Safari", "com.apple.Safari", monitor: monitor)
        // The password app's copy lands after the switch was handled.
        pasteboard.copy(text("correct horse battery staple"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [true])
        // From the next poll on, Safari's copies are its own.
        pasteboard.copy(text("shopping list"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
    }

    @Test func aCopyMadeBeforeSwitchingToAPasswordAppIsNotASecret() {
        let front = FrontmostApp("Notes", "com.apple.Notes")
        let monitor = makeMonitor(front)
        pasteboard.copy(text("shopping list"))
        front.switchTo("Passwords", "com.apple.Passwords", monitor: monitor)
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false])
        #expect(store.items[0].sourceApp == "Notes")
    }

    @Test func withSecretsOffEveryCopyIsSaved() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front, detecting: false)
        pasteboard.copy(text("correct horse battery staple"))
        monitor.tick()
        front.switchTo("Terminal", "com.apple.Terminal", monitor: monitor)
        monitor.tick()
        pasteboard.copy(text(fakeGitHubToken))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, false])
    }

    @Test func turningSecretsOffLeavesSecretsToExpire() {
        let front = FrontmostApp("Terminal", "com.apple.Terminal")
        let monitor = makeMonitor(front)
        pasteboard.copy(text(fakeGitHubToken))
        monitor.tick()
        store.detectsSecrets = false
        pasteboard.copy(text("plain"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
    }

    @Test func aSwitchWhilePausedRecordsNothing() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        monitor.isPaused = true
        pasteboard.copy(text("correct horse battery staple"))
        front.switchTo("Safari", "com.apple.Safari", monitor: monitor)
        monitor.isPaused = false
        monitor.tick()
        #expect(store.items.isEmpty)
    }
}
