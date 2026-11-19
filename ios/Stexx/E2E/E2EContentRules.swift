import Foundation

/// The trust-ramp text rules, run on the plaintext before it's encrypted
/// (`docs/security.md` section 4, "With end-to-end encrypted chats"). The
/// server can't read ciphertext, so for encrypted messages the app enforces
/// them, using `contentRules` from `GET /e2e/config`.
///
/// A port of `containsLink` and `normalizeForDuplicate` in
/// `server/src/lib/abuse/content.ts`; keep them in step. The payment, crypto
/// and redirect handle rules aren't ported by hand: they are read from
/// `content-rules.json`, a byte-identical copy of the server's table
/// (`server/src/lib/abuse/content-rules.json`; the server's tests fail if the
/// two differ, and both test suites run the vectors in it). The messages match
/// the server's 403 `links_not_allowed` / `handles_not_allowed` /
/// `duplicate_message`.
enum E2EContentRules {
    enum Violation: LocalizedError, Equatable {
        case linksNotAllowed
        case handlesNotAllowed
        case duplicateMessage

        var errorDescription: String? {
            switch self {
            case .linksNotAllowed:
                String(localized: "New accounts can't send links yet. Try again in a day or so.")
            case .handlesNotAllowed:
                String(localized: "New accounts can't share payment, crypto or messenger handles yet. Try again in a day or so.")
            case .duplicateMessage:
                String(localized: "You've sent this exact message to several people already. Try something personal.")
            }
        }
    }

    // Same TLD list as the server.
    private static let tlds =
        "com|net|org|io|co|me|app|gg|ly|link|xyz|site|online|info|biz|us|uk|ca|de|ru|cn|tv|cc|to|be|ai|so|sh|club|live|shop|store|top|vip|fun|page|bio|lol|wtf|gay|dating|chat|social|fans|onlyfans|cash|pay|money"

    /// The server's regex with JavaScript's ASCII `\b` spelled out (ICU's
    /// `\b` is Unicode-aware, JS's isn't): a word boundary before an ASCII
    /// letter/digit means "not preceded by [A-Za-z0-9_]", and after one,
    /// "not followed by [A-Za-z0-9_]".
    private static let linkPattern: NSRegularExpression = {
        let before = "(?<![A-Za-z0-9_])"
        let after = "(?![A-Za-z0-9_])"
        let pattern =
            "(?:\(before)[a-z][a-z0-9+.-]{1,15}://\\S)"
            + "|(?:\(before)www\\.\\S)"
            + "|(?:\(before)[a-z0-9-]{1,63}\\s*(?:\\.|\\(dot\\)|\\[dot\\])\\s*(?:\(tlds))\(after)(?:/\\S*)?)"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// True if `text` contains something that looks like a link (after NFKC
    /// normalization, so full-width and styled letters count).
    static func containsLink(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let range = NSRange(normalized.startIndex..., in: normalized)
        return linkPattern.firstMatch(in: normalized, range: range) != nil
    }

    // MARK: Handles (shared table)

    /// One row of `content-rules.json`'s `handleRules`.
    struct HandleRule: Decodable, Sendable, Equatable {
        enum Kind: String, Decodable, Sendable {
            case payment, crypto, redirect
        }

        let id: String
        let kind: Kind
        let caseInsensitive: Bool
        let pattern: String
    }

    private struct Table: Decodable {
        let version: Int
        let handleRules: [HandleRule]
    }

    private final class BundleToken {}

    /// The shared table, from the app bundle (also when hosted by unit tests).
    static let tableURL = Bundle(for: BundleToken.self).url(forResource: "content-rules", withExtension: "json")

    /// The handle rules, compiled once. A rule ICU can't compile is left out
    /// (the tests check none is).
    static let handleRules: [(rule: HandleRule, regex: NSRegularExpression)] = {
        guard let url = tableURL, let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data)
        else { return [] }
        return table.handleRules.compactMap { rule in
            let options: NSRegularExpression.Options = rule.caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) else { return nil }
            return (rule, regex)
        }
    }()

    /// NFKC, then zero-width characters (U+200B-U+200D, U+2060, U+FEFF)
    /// removed: the server's `normalizeForRules`.
    static func normalizeForRules(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let zeroWidth: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: normalized.unicodeScalars.filter { !zeroWidth.contains($0.value) })
        return String(scalars)
    }

    /// Ids of every handle rule that matches `text`, in table order.
    static func matchingHandleRules(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = normalizeForRules(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        return handleRules
            .filter { $0.regex.firstMatch(in: normalized, range: range) != nil }
            .map(\.rule.id)
    }

    /// True if `text` has a payment or crypto handle or an off-platform
    /// redirect (Cash App, Venmo, PayPal.me, wallet addresses, Telegram,
    /// WhatsApp, OnlyFans...).
    static func containsHandle(_ text: String) -> Bool {
        !matchingHandleRules(text).isEmpty
    }

    /// Case- and whitespace-insensitive form for duplicate detection.
    static func normalizeForDuplicate(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Throws if a restricted account may not send `text` to `conversationID`.
    /// `recentSends` are the user's own sends of the last 24 hours.
    static func check(
        _ text: String,
        conversationID: Conversation.ID,
        rules: E2EConfig.ContentRules,
        recentSends: [E2EHistory.Send],
        now: Date = .now
    ) throws {
        guard rules.restricted else { return }
        if rules.noLinks && containsLink(text) { throw Violation.linksNotAllowed }
        if rules.noHandles && containsHandle(text) { throw Violation.handlesNotAllowed }
        let normalized = normalizeForDuplicate(text)
        // The server compares JavaScript string lengths (UTF-16 code units).
        guard normalized.utf16.count >= rules.duplicateMinLength else { return }
        let since = now.addingTimeInterval(-24 * 3600)
        let others = Set(recentSends
            .filter { $0.sentAt > since && $0.conversationID != conversationID && $0.normalized == normalized }
            .map(\.conversationID))
        if others.count >= rules.duplicateRecipients { throw Violation.duplicateMessage }
    }
}
