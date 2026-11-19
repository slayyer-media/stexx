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

    // MARK: Shared table (content-rules.json, a copy of the server's)

    private struct Vectors: Decodable {
        struct Handle: Decodable {
            let text: String
            let matches: [String]
        }

        struct Links: Decodable {
            let match: [String]
            let noMatch: [String]
        }

        let handles: [Handle]
        let links: Links
    }

    private struct TableFile: Decodable {
        let handleRules: [E2EContentRules.HandleRule]
        let vectors: Vectors
    }

    private static func table() throws -> TableFile {
        let url = try #require(E2EContentRules.tableURL, "content-rules.json is missing from the app bundle")
        return try JSONDecoder().decode(TableFile.self, from: Data(contentsOf: url))
    }

    @Test("Every rule in the shared table compiles with ICU")
    func rulesCompile() throws {
        let table = try Self.table()
        #expect(table.handleRules.count > 10)
        #expect(E2EContentRules.handleRules.map(\.rule) == table.handleRules)
    }

    @Test("The server's handle vectors match exactly the same rules here")
    func handleVectors() throws {
        let table = try Self.table()
        #expect(table.vectors.handles.count > 30)
        for vector in table.vectors.handles {
            #expect(
                E2EContentRules.matchingHandleRules(vector.text).sorted() == vector.matches.sorted(),
                "\(vector.text)"
            )
        }
    }

    @Test("The server's link vectors agree with containsLink")
    func linkVectors() throws {
        let table = try Self.table()
        for text in table.vectors.links.match { #expect(E2EContentRules.containsLink(text), "\(text)") }
        for text in table.vectors.links.noMatch { #expect(!E2EContentRules.containsLink(text), "\(text)") }
    }

    @Test("Handles are refused for restricted accounts when the server says so, and only then")
    func handlesRefused() throws {
        var rules = Self.restricted
        try E2EContentRules.check("venmo me @jake-b", conversationID: "c1", rules: rules, recentSends: [])
        rules.noHandles = true
        #expect(throws: E2EContentRules.Violation.handlesNotAllowed) {
            try E2EContentRules.check("venmo me @jake-b", conversationID: "c1", rules: rules, recentSends: [])
        }
        #expect(throws: E2EContentRules.Violation.handlesNotAllowed) {
            try E2EContentRules.check("btc: 1BoatSLRHtKNngkdXEeobR76b53LETtpyT", conversationID: "c1", rules: rules, recentSends: [])
        }
        try E2EContentRules.check("drinks are $5 at happy hour", conversationID: "c1", rules: rules, recentSends: [])
        var open = E2EConfig.ContentRules.unrestricted
        open.noHandles = false
        try E2EContentRules.check("venmo me @jake-b", conversationID: "c1", rules: open, recentSends: [])
    }

    @Test("contentRules decode with and without noHandles")
    func decodeNoHandles() throws {
        let old = #"{"restricted":true,"noLinks":true,"duplicateRecipients":3,"duplicateMinLength":16}"#
        let new = #"{"restricted":true,"noLinks":true,"noHandles":true,"duplicateRecipients":3,"duplicateMinLength":16}"#
        #expect(try JSONDecoder().decode(E2EConfig.ContentRules.self, from: Data(old.utf8)).noHandles == false)
        #expect(try JSONDecoder().decode(E2EConfig.ContentRules.self, from: Data(new.utf8)).noHandles == true)
    }
}
