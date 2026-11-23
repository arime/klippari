import Foundation

/// Recognises copies that are probably secrets, which the history keeps
/// in memory only, for `HistoryStore.secretLifetime`, and shows masked.
///
/// Only while the Secrets setting is on, and for new copies only: a copy
/// is a secret when it comes from a password app, or when it is mostly a
/// credential in a well-known format. There is deliberately no entropy
/// guess: it would flag ordinary hashes and UUIDs.
public enum Secrets {
    /// Pasteboard type in which apps following the nspasteboard.org
    /// convention name themselves, as a bundle identifier.
    public static let sourceType = "org.nspasteboard.source"

    /// Password apps whose copies are secrets whatever they look like.
    /// Apps that mark their copies as concealed are skipped before this.
    public static let passwordApps: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "org.keepassxc.keepassxc",
    ]

    private struct Format {
        let regex: NSRegularExpression
        /// Text every match contains, one of these at least, in UTF-8.
        /// Looking for it is far cheaper than running the regex, which is
        /// skipped when none is there: most copies hold no credential.
        let anchors: [[UInt8]]
        /// Whether the anchors are looked for ignoring ASCII case, as
        /// the regex is. They are then given in small letters.
        let ignoringCase: Bool
        /// Whether the mask keeps the last few characters, to tell two
        /// keys apart. Not for a password, of which nothing shows.
        let showsTail: Bool

        init(
            _ pattern: String, anchors: [String], ignoringCase: Bool = false, showsTail: Bool = true
        ) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.anchors = anchors.map { Array($0.utf8) }
            self.ignoringCase = ignoringCase
            self.showsTail = showsTail
        }

        func mayOccur(in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            anchors.contains { anchor in
                ignoringCase ? Secrets.contains(bytes, lowercased: anchor) : Secrets.contains(bytes, anchor)
            }
        }

        func matches(in string: String) -> [NSTextCheckingResult] {
            regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
        }
    }

    /// The formats that may match in `string`: those with an anchor in it.
    private static func formats(possiblyIn string: String) -> [Format] {
        var string = string
        string.makeContiguousUTF8()
        return string.utf8.withContiguousStorageIfAvailable { bytes in
            formats.filter { $0.mayOccur(in: bytes) }
        } ?? formats
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = bytes.baseAddress, needle.count <= bytes.count else { return false }
        return needle.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, needle.count) != nil }
    }

    /// `needle` in small ASCII letters, found in `bytes` whatever their case.
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, lowercased needle: [UInt8]) -> Bool {
        guard let first = needle.first, needle.count <= bytes.count else { return false }
        func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte | 0x20 : byte }
        var index = 0
        let last = bytes.count - needle.count
        while index <= last {
            if lower(bytes[index]) == first {
                var offset = 1
                while offset < needle.count, lower(bytes[index + offset]) == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }

    /// Credentials found and masked within a line. A private key is not
    /// among them: it spans lines, and is found as a PEM block (see
    /// `isMostlyCredential`). Group 1 is the prefix that names the kind of
    /// credential and stays visible. Order matters: earlier formats win
    /// where matches overlap ('sk-ant-' before 'sk-').
    private static let formats: [Format] = [
        Format(#"\b(github_pat_)[A-Za-z0-9_]{22,}"#, anchors: ["github_pat_"]),
        Format(#"\b(gh[pousr]_)[A-Za-z0-9]{36,}"#, anchors: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]),
        Format(#"\b(sk-ant-)[A-Za-z0-9_-]{20,}"#, anchors: ["sk-ant-"]),
        // A bare 'sk-' also starts URL slugs and CSS class names
        // ('sk-loading-spinner'), so the key itself must be long and mix
        // capitals, small letters and digits, as generated keys do.
        Format(#"\b(sk-(?:proj-|svcacct-|admin-)?)(?=[A-Za-z0-9_-]*[A-Z])(?=[A-Za-z0-9_-]*[a-z])(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{32,}"#, anchors: ["sk-"]),
        Format(#"\b((?:sk|rk)_(?:live|test)_)[A-Za-z0-9]{24,}"#, anchors: ["_live_", "_test_"]), // Stripe
        Format(#"\b(glpat-)[A-Za-z0-9_-]{20,}"#, anchors: ["glpat-"]), // GitLab
        Format(#"\b(AIza)[0-9A-Za-z_-]{35}\b"#, anchors: ["AIza"]), // Google API key
        Format(#"\b(npm_)[A-Za-z0-9]{36}\b"#, anchors: ["npm_"]),
        Format(#"\b(hf_)[A-Za-z0-9]{34,}\b"#, anchors: ["hf_"]), // Hugging Face
        Format(#"\b(SG\.)[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"#, anchors: ["SG."]), // SendGrid
        Format(#"\b(AGE-SECRET-KEY-1)[0-9A-Z]{58}\b"#, anchors: ["AGE-SECRET-KEY-1"]),
        // An AWS access key ID is not secret by itself, but it is rarely
        // copied without its secret key, which has no format of its own:
        // that is only recognised where it is named.
        Format(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, anchors: ["AKIA", "ASIA"]),
        Format(#"(?i)\b(aws_secret_access_key\s*[=:]\s*["']?)[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])"#,
               anchors: ["aws_secret_access_key"], ignoringCase: true),
        // A temporary credential's session token, where it is named.
        Format(#"(?i)\b(aws_session_token\s*[=:]\s*["']?)[A-Za-z0-9/+=]{100,}"#,
               anchors: ["aws_session_token"], ignoringCase: true),
        Format(#"\b(xox[abposr]-|xapp-)[A-Za-z0-9-]{10,}"#, anchors: ["xox", "xapp-"]), // Slack
        Format(#"\b(eyJ)[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, anchors: ["eyJ"]),
        Format(#"\b(Bearer\s+)[A-Za-z0-9._~+/-]{20,}=*"#, anchors: ["Bearer"]),
        // A password in a URL ('https://user:password@host').
        Format(#"\b([a-z][a-z0-9+.-]*://[^\s/:@]+:)[^\s/@]{3,}(?=@)"#, anchors: ["://"], showsTail: false),
    ]

    /// Stands in for the hidden part. Always the same length, so the mask
    /// does not tell how long the secret is.
    public static let dots = "••••••"

    /// Why a copy is taken for a secret.
    public enum Reason: Equatable, Sendable {
        /// Its text is the secret: a credential in a known format. Earlier
        /// copies of the same text go too.
        case content
        /// Only that it came from a password app. Earlier copies of the
        /// same text, which were saved as ordinary items, are left alone.
        case sourceApp
    }

    /// Why this copy should be kept as a secret; nil when it should not.
    /// `frontmostBundleID` is the app that was in front when the copy was
    /// made; the copy's own source marker wins over it when present.
    /// `passwordAppWasFrontmost` counts as coming from a password app.
    public static func reason(
        for content: ClipContent, frontmostBundleID: String?, passwordAppWasFrontmost: Bool = false
    ) -> Reason? {
        if let string = content.plainString, isMostlyCredential(string) { return .content }
        let declared = content.data(for: sourceType).flatMap { String(data: $0, encoding: .utf8) }
        if passwordAppWasFrontmost || isPasswordApp(declared ?? frontmostBundleID) { return .sourceApp }
        return nil
    }

    public static func isPasswordApp(_ bundleID: String?) -> Bool {
        bundleID.map(passwordApps.contains) ?? false
    }

    /// A line up to this long that holds a credential is taken for one.
    public static let longestCredentialLine = 256
    /// A longer line is taken for one when credentials cover at least
    /// this share of it, as a long access token or JWT does on its own,
    /// in an `Authorization: Bearer …` header or in a `curl` command.
    public static let credentialShareOfLongLine = 0.8
    /// A copy with more lines than this is a longer text, even if every
    /// line holds a credential.
    public static let mostCredentialLines = 5

    /// Whether the copy is mostly credentials, not a longer text that
    /// merely holds one.
    ///
    /// PEM blocks come out first: a copy holding a private key block, and
    /// besides its PEM blocks (a certificate chain, say) nothing but what
    /// the line rule below accepts, is a secret. A private key cut short,
    /// its END line missing because the selection stopped early, counts
    /// when it runs to the end of the copy. Then comment lines
    /// (`# prod token`, `// …`, `; …`) and section headers (`[default]`)
    /// that hold no credential themselves are set aside, as are blank
    /// lines. What is left must be at most
    /// `mostCredentialLines` lines, each holding a credential and either
    /// at most `longestCredentialLine` characters long or mostly the
    /// credential, with at least one such line unless a private key came
    /// out.
    ///
    /// So `export GH_TOKEN=…`, a database URL with its password, a bare
    /// 1000-character JWT, an AWS access key ID with its named secret
    /// key (and session token), a token under a comment, or a
    /// commented-out token are secrets; a docker-compose file, a log or documentation
    /// with a token in it is saved like any other copy. A bare AWS secret
    /// access key has no format of its own, so it counts only where it is
    /// named (`aws_secret_access_key = …`).
    public static func isMostlyCredential(_ string: String) -> Bool {
        var text = string
        var holdsPrivateKey = false
        // Most copies hold no PEM block, and a large one is then spared
        // the search.
        if text.contains("-----BEGIN ") {
            let whole = NSRange(text.startIndex..., in: text)
            let blocks = pemBlock.matches(in: text, range: whole)
            // A private key cut short runs to the end of the copy, so it
            // can only come after the whole blocks, never inside one.
            let cutShort = truncatedPrivateKey.firstMatch(in: text, range: whole)
            holdsPrivateKey = cutShort != nil || blocks.contains { match in
                Range(match.range(at: 1), in: text).map { text[$0].contains("PRIVATE KEY") } ?? false
            }
            if holdsPrivateKey {
                let ranges = blocks.map(\.range) + (cutShort.map { [$0.range] } ?? [])
                for nsRange in ranges.sorted(by: { $0.location > $1.location }) {
                    if let range = Range(nsRange, in: text) { text.removeSubrange(range) }
                }
            }
        }
        // Lines are counted before any is matched against the formats,
        // and counting stops past the most allowed, so a large copy, such
        // as a source file, costs little in the clipboard poll. Comments
        // and headers are looked at only once the other lines are known
        // to be few.
        let nsText = text as NSString
        var lines: [String] = []
        var comments: [(line: String, range: NSRange)] = []
        var tooMany = false
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length), options: [.byLines]
        ) { substring, range, _, stop in
            let line = (substring ?? "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            if isCommentOrHeader(line) {
                comments.append((line, range))
            } else {
                lines.append(line)
                if lines.count > mostCredentialLines {
                    tooMany = true
                    stop.pointee = true
                }
            }
        }
        if tooMany { return false }
        // A comment that holds a credential itself, as a commented-out
        // `# export GH_TOKEN=…` does, still counts as a line. One pass of
        // each format over the whole copy tells which comments may hold
        // one; only those are matched line by line. A match within a line
        // is a match in the whole copy too, so none is missed.
        if !comments.isEmpty {
            var found = IndexSet()
            for format in formats(possiblyIn: text) {
                for match in format.matches(in: text) {
                    found.insert(integersIn: match.range.lowerBound..<match.range.upperBound)
                }
            }
            for comment in comments
            where found.intersects(integersIn: comment.range.lowerBound..<comment.range.upperBound)
                && holdsCredential(comment.line) {
                lines.append(comment.line)
                if lines.count > mostCredentialLines { return false }
            }
        }
        guard holdsPrivateKey || !lines.isEmpty else { return false }
        return lines.allSatisfy(isCredentialLine)
    }

    /// A PEM block, with its label as group 1.
    private static let pemBlock = try! NSRegularExpression(
        pattern: #"-----BEGIN ([A-Z0-9 ]+)-----[\s\S]*?-----END \1-----"#
    )

    /// A private key with no END line, to the end of the copy: its BEGIN
    /// line, any armor headers (`Proc-Type: …`, `Version: …`), then
    /// nothing but base64 lines, the first at least 16 characters long.
    /// A BEGIN line alone, or one followed by prose, is not one.
    private static let truncatedPrivateKey = try! NSRegularExpression(
        pattern: #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[ \t]*\r?\n"#
            + #"(?:[ \t]*[A-Za-z][A-Za-z0-9-]*:[^\r\n]*\r?\n)*(?:[ \t]*\r?\n)?"#
            + #"(?=[ \t]*[A-Za-z0-9+/=]{16})(?:[ \t]*[A-Za-z0-9+/=]+[ \t]*(?:\r?\n|$))+\s*\z"#
    )

    /// A comment line (`#`, `//`, `;`) or an INI-style section header
    /// (`[default]`), which only names what follows. Plain prefix checks:
    /// every line of a copy goes through this.
    private static func isCommentOrHeader(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";") { return true }
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { return false }
        return !line.dropFirst().dropLast().contains("]")
    }

    private static func holdsCredential(_ line: String) -> Bool {
        formats(possiblyIn: line).contains { format in
            format.regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    /// A private key's BEGIN line alone is not one: a key is found as a
    /// PEM block, even on one line.
    private static func isCredentialLine(_ line: String) -> Bool {
        let whole = NSRange(line.startIndex..., in: line)
        var covered = IndexSet()
        for format in formats(possiblyIn: line) {
            for match in format.matches(in: line) {
                covered.insert(integersIn: match.range.lowerBound..<match.range.upperBound)
            }
        }
        guard !covered.isEmpty else { return false }
        // Characters, not UTF-16 units, for the length; the share is of
        // UTF-16 units on both sides.
        return line.count <= longestCredentialLine
            || Double(covered.count) >= credentialShareOfLongLine * Double(whole.length)
    }

    /// One line as a secret's row shows it. The first credential in a
    /// known format keeps its prefix and last few characters, so two keys
    /// of the same kind can be told apart. Before it, only a variable name
    /// ('export GH_TOKEN=') stays; anything else there, and anything after
    /// it, is hidden, since a secret often sits beside another one. A line
    /// with no known credential is one whole secret, as a password is,
    /// and shows as the dots alone: none of its characters, nor its
    /// length.
    public static func mask(_ line: String) -> String {
        if isArmorLine(line) { return line }
        guard let (range, prefix, showsTail) = credentials(in: line).first else { return dots }
        let before = String(line[..<range.lowerBound])
        let after = line[range.upperBound...]
        var result = before.isEmpty || isAssignment(before) ? before : dots + " "
        result += maskCredential(String(line[range]), prefix: prefix, showsTail: showsTail)
        if after.trimmingCharacters(in: closing).isEmpty {
            result += after
        } else {
            result += " " + dots
        }
        return result
    }

    /// What may close a credential without hiding anything: quotes,
    /// separators and spaces.
    private static let closing = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`;,"))

    private static let assignment = try! NSRegularExpression(
        pattern: #"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*[=:]\s*["'`]?$"#
    )

    /// True for the start of a line that only names where the credential
    /// goes: 'export GH_TOKEN=', 'api_key: "'.
    private static func isAssignment(_ text: String) -> Bool {
        assignment.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let armor = try! NSRegularExpression(pattern: #"^-----(?:BEGIN|END) [A-Z0-9 ]+-----$"#)

    /// A whole '-----BEGIN … KEY-----' or '-----END … KEY-----' line names
    /// what follows and is not secret itself. A key collapsed onto one
    /// line is not such a line.
    private static func isArmorLine(_ line: String) -> Bool {
        armor.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Non-overlapping maskable credentials in `line`, in order, each with
    /// its visible prefix.
    private static func credentials(in line: String) -> [(Range<String.Index>, String, Bool)] {
        var found: [(Range<String.Index>, String, Bool)] = []
        for format in formats(possiblyIn: line) {
            for match in format.matches(in: line) {
                guard let range = Range(match.range, in: line),
                      let prefixRange = Range(match.range(at: 1), in: line),
                      !found.contains(where: { $0.0.overlaps(range) })
                else { continue }
                found.append((range, String(line[prefixRange]), format.showsTail))
            }
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    private static func maskCredential(_ credential: String, prefix: String, showsTail: Bool) -> String {
        let body = credential.count - prefix.count
        let tail = !showsTail ? 0 : body >= 16 ? 4 : body >= 8 ? 2 : 0
        return prefix + dots + String(credential.suffix(tail))
    }
}
