import Foundation

/// Recognises copies that are probably secrets, which the history keeps
/// in memory only, for `HistoryStore.secretLifetime`, and shows masked.
///
/// Only while the Secrets setting is on, and for new copies only: a copy
/// is a secret when it comes from a password app, when it is mostly a
/// credential in a well-known format, or when it contains a text the
/// user asked to have masked always. There is deliberately no entropy
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
        /// Detection only: never masked in place (a private key's header
        /// line is not the secret).
        let maskable: Bool
        /// Whether the mask keeps the last few characters, to tell two
        /// keys apart. Not for a password, of which nothing shows.
        let showsTail: Bool

        init(_ pattern: String, maskable: Bool = true, showsTail: Bool = true) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.maskable = maskable
            self.showsTail = showsTail
        }
    }

    /// Group 1 of a maskable format is the prefix that names the kind of
    /// credential and stays visible. Order matters: earlier formats win
    /// where matches overlap ('sk-ant-' before 'sk-').
    private static let formats: [Format] = [
        Format(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#, maskable: false),
        Format(#"\b(github_pat_)[A-Za-z0-9_]{22,}"#),
        Format(#"\b(gh[pousr]_)[A-Za-z0-9]{36,}"#),
        Format(#"\b(sk-ant-)[A-Za-z0-9_-]{20,}"#),
        // A bare 'sk-' also starts URL slugs and CSS class names
        // ('sk-loading-spinner'), so the key itself must be long and mix
        // capitals, small letters and digits, as generated keys do.
        Format(#"\b(sk-(?:proj-|svcacct-|admin-)?)(?=[A-Za-z0-9_-]*[A-Z])(?=[A-Za-z0-9_-]*[a-z])(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{32,}"#),
        Format(#"\b((?:sk|rk)_(?:live|test)_)[A-Za-z0-9]{24,}"#), // Stripe
        Format(#"\b(glpat-)[A-Za-z0-9_-]{20,}"#), // GitLab
        Format(#"\b(AIza)[0-9A-Za-z_-]{35}\b"#), // Google API key
        Format(#"\b(npm_)[A-Za-z0-9]{36}\b"#),
        Format(#"\b(hf_)[A-Za-z0-9]{34,}\b"#), // Hugging Face
        Format(#"\b(SG\.)[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"#), // SendGrid
        Format(#"\b(AGE-SECRET-KEY-1)[0-9A-Z]{58}\b"#),
        // An AWS access key ID is not secret by itself, but it is rarely
        // copied without its secret key, which has no format of its own:
        // that is only recognised where it is named.
        Format(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Format(#"(?i)\b(aws_secret_access_key\s*[=:]\s*["']?)[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])"#),
        // A temporary credential's session token, where it is named.
        Format(#"(?i)\b(aws_session_token\s*[=:]\s*["']?)[A-Za-z0-9/+=]{100,}"#),
        Format(#"\b(xox[abposr]-|xapp-)[A-Za-z0-9-]{10,}"#), // Slack
        Format(#"\b(eyJ)[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        Format(#"\b(Bearer\s+)[A-Za-z0-9._~+/-]{20,}=*"#),
        // A password in a URL ('https://user:password@host').
        Format(#"\b([a-z][a-z0-9+.-]*://[^\s/:@]+:)[^\s/@]{3,}(?=@)"#, showsTail: false),
    ]

    /// Stands in for the hidden part. Always the same length, so the mask
    /// does not tell how long the secret is.
    public static let dots = "••••••"

    /// Why a copy is taken for a secret.
    public enum Reason: Equatable, Sendable {
        /// Its text is the secret: a credential in a known format, or a
        /// text the user asked to have masked always. Earlier copies of
        /// the same text go too.
        case content
        /// Only that it came from a password app. Earlier copies of the
        /// same text, which were saved as ordinary items, are left alone.
        case sourceApp
    }

    /// Why this copy should be kept as a secret; nil when it should not.
    /// `frontmostBundleID` is the app that was in front when the copy was
    /// made; the copy's own source marker wins over it when present.
    /// `passwordAppWasFrontmost` counts as coming from a password app.
    /// `maskedTexts` are texts the user asked to have masked always: a
    /// copy whose text contains one, ignoring case, is a secret.
    public static func reason(
        for content: ClipContent, frontmostBundleID: String?,
        passwordAppWasFrontmost: Bool = false, maskedTexts: [String] = []
    ) -> Reason? {
        if let string = content.plainString,
           isMostlyCredential(string) || containsMaskedText(string, maskedTexts) {
            return .content
        }
        let declared = content.data(for: sourceType).flatMap { String(data: $0, encoding: .utf8) }
        if passwordAppWasFrontmost || isPasswordApp(declared ?? frontmostBundleID) { return .sourceApp }
        return nil
    }

    public static func isPasswordApp(_ bundleID: String?) -> Bool {
        bundleID.map(passwordApps.contains) ?? false
    }

    public static func containsCredential(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return formats.contains { $0.regex.firstMatch(in: string, range: range) != nil }
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
    /// the line rule below accepts, is a secret. Then comment lines
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
        let blocks = pemBlock.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let holdsPrivateKey = blocks.contains { match in
            Range(match.range(at: 1), in: text).map { text[$0].contains("PRIVATE KEY") } ?? false
        }
        if holdsPrivateKey {
            for match in blocks.reversed() {
                if let range = Range(match.range, in: text) { text.removeSubrange(range) }
            }
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // A comment that holds a credential itself, as a commented-out
            // `# export GH_TOKEN=…` does, still counts.
            .filter { !$0.isEmpty && !(isCommentOrHeader($0) && !holdsCredential($0)) }
        guard lines.count <= mostCredentialLines, holdsPrivateKey || !lines.isEmpty else { return false }
        return lines.allSatisfy(isCredentialLine)
    }

    /// A PEM block, with its label as group 1.
    private static let pemBlock = try! NSRegularExpression(
        pattern: #"-----BEGIN ([A-Z0-9 ]+)-----[\s\S]*?-----END \1-----"#
    )

    private static let commentOrHeader = try! NSRegularExpression(pattern: #"^(?:#|//|;|\[[^\]]+\]$)"#)

    /// A comment line or an INI-style section header, which only names
    /// what follows.
    private static func isCommentOrHeader(_ line: String) -> Bool {
        commentOrHeader.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func holdsCredential(_ line: String) -> Bool {
        let whole = NSRange(line.startIndex..., in: line)
        return formats.contains { $0.maskable && $0.regex.firstMatch(in: line, range: whole) != nil }
    }

    private static func isCredentialLine(_ line: String) -> Bool {
        let whole = NSRange(line.startIndex..., in: line)
        var covered = IndexSet()
        // A private key's header alone is not one: a whole key is found
        // as a PEM block, even on one line.
        for format in formats where format.maskable {
            for match in format.regex.matches(in: line, range: whole) {
                covered.insert(integersIn: match.range.lowerBound..<match.range.upperBound)
            }
        }
        guard !covered.isEmpty else { return false }
        // Characters, not UTF-16 units, for the length; the share is of
        // UTF-16 units on both sides.
        return line.count <= longestCredentialLine
            || Double(covered.count) >= credentialShareOfLongLine * Double(whole.length)
    }


    /// Whether `string` contains one of `texts`, ignoring case. Blank
    /// entries never match.
    public static func containsMaskedText(_ string: String, _ texts: [String]) -> Bool {
        texts.contains { text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && string.range(of: text, options: .caseInsensitive) != nil
        }
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
        let whole = NSRange(line.startIndex..., in: line)
        var found: [(Range<String.Index>, String, Bool)] = []
        for format in formats where format.maskable {
            for match in format.regex.matches(in: line, range: whole) {
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
