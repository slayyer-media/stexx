import Foundation
import Testing
@testable import Stexx

/// The in-app port of the server's text rules (`server/src/lib/abuse/content.ts`).
struct E2EContentRulesTests {
    // The server's own vectors (server/test/trust.test.ts), plus a few more.
    @Test("containsLink matches the server", arguments: [
        "see https://x.co/a", "www.spam.example", "add me on spam-site.com", "t.me/someone", "cash.app/$me",
        "my site: hot-pics . xyz", "onlyfans(dot)com/x", "HTTP://SHOUT.NET", "insta[dot]me", "ｗｗｗ.example.com",
    ])
    func links(_ text: String) {
        #expect(E2EContentRules.containsLink(text))
    }

    @Test("containsLink leaves ordinary text alone", arguments: [
        "hey, how's it going?", "I'm 6.2 ft lol", "e.g. coffee at 5.30", "ok... sure", "3.14159", "u.s. army vet",
        "café.com", "",
    ])
    func noLinks(_ text: String) {
        #expect(!E2EContentRules.containsLink(text))
    }

    @Test("Duplicate normalization ignores case and spacing")
    func normalize() {
        #expect(E2EContentRules.normalizeForDuplicate("  Hey   THERE\n handsome ") == "hey there handsome")
    }

    private static let restricted = E2EConfig.ContentRules(restricted: true, noLinks: true, duplicateRecipients: 3, duplicateMinLength: 16)

    private func sends(_ text: String, to conversations: [String]) -> [E2EHistory.Send] {
        conversations.map { E2EHistory.Send(conversationID: $0, normalized: E2EContentRules.normalizeForDuplicate(text), sentAt: .now) }
    }

    @Test("The same long text to a 4th person is refused; the same thread, short texts and old sends are fine")
    func duplicates() throws {
        let text = "Hey there, want to grab a coffee?"
        let three = sends(text, to: ["c1", "c2", "c3"])
        #expect(throws: E2EContentRules.Violation.duplicateMessage) {
            try E2EContentRules.check(text.uppercased(), conversationID: "c4", rules: Self.restricted, recentSends: three)
        }
        try E2EContentRules.check(text, conversationID: "c3", rules: Self.restricted, recentSends: sends(text, to: ["c1", "c2", "c3"]))
        try E2EContentRules.check("hey", conversationID: "c4", rules: Self.restricted, recentSends: sends("hey", to: ["c1", "c2", "c3"]))
        let old = three.map { E2EHistory.Send(conversationID: $0.conversationID, normalized: $0.normalized, sentAt: .now.addingTimeInterval(-25 * 3600)) }
        try E2EContentRules.check(text, conversationID: "c4", rules: Self.restricted, recentSends: old)
    }

    @Test("Unrestricted accounts skip both rules")
    func unrestricted() throws {
        try E2EContentRules.check("www.example.com", conversationID: "c1", rules: .unrestricted, recentSends: [])
    }

    @Test("Links are refused for restricted accounts")
    func linkRefused() {
        #expect(throws: E2EContentRules.Violation.linksNotAllowed) {
            try E2EContentRules.check("www.example.com", conversationID: "c1", rules: Self.restricted, recentSends: [])
        }
    }
}
