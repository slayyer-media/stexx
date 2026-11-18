import Foundation
import Testing
@testable import Stexx

struct ReportEvidenceTests {
    private let reported = "p_them"
    private let me = "p_me"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(
        _ id: String,
        from sender: String,
        text: String? = nil,
        photo: Bool = false,
        at offset: TimeInterval
    ) -> Message {
        Message(
            id: id,
            conversationID: "c1",
            senderID: sender,
            text: text,
            attachment: photo ? Message.Attachment(kind: .photo) : nil,
            sentAt: base.addingTimeInterval(offset),
            status: .read
        )
    }

    @Test("Only selected messages are included, oldest first")
    func selectionAndOrdering() {
        let messages = [
            message("m3", from: reported, text: "third", at: 30),
            message("m1", from: reported, text: "first", at: 10),
            message("m2", from: me, text: "second", at: 20),
        ]
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: ["m3", "m1"], reportedID: reported)
        #expect(evidence.map(\.messageID) == ["m1", "m3"])
        #expect(evidence.map(\.text) == ["first", "third"])
        #expect(!evidence.contains { $0.text == "second" })
    }

    @Test("Nothing selected means nothing included")
    func emptySelection() {
        let messages = [message("m1", from: reported, text: "hi", at: 1)]
        #expect(ReportEvidence.from(messages: messages, selectedIDs: [], reportedID: reported).isEmpty)
    }

    @Test("fromReported reflects who sent the message")
    func fromReported() {
        let messages = [
            message("m1", from: reported, text: "a", at: 1),
            message("m2", from: me, text: "b", at: 2),
        ]
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: ["m1", "m2"], reportedID: reported)
        #expect(evidence.map(\.fromReported) == [true, false])
    }

    @Test("Photos become hasPhoto, keeping any caption")
    func photos() {
        let messages = [
            message("m1", from: reported, photo: true, at: 1),
            message("m2", from: reported, text: " caption ", photo: true, at: 2),
            message("m3", from: reported, text: "plain", at: 3),
        ]
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: ["m1", "m2", "m3"], reportedID: reported)
        #expect(evidence[0].hasPhoto == true)
        #expect(evidence[0].text == nil)
        #expect(evidence[1].hasPhoto == true)
        #expect(evidence[1].text == "caption")
        #expect(evidence[2].hasPhoto == nil)
    }

    @Test("Blank text becomes nil and empty messages are dropped")
    func blankText() {
        let messages = [
            message("m1", from: reported, text: "   \n", at: 1),
            message("m2", from: reported, text: "", photo: true, at: 2),
        ]
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: ["m1", "m2"], reportedID: reported)
        #expect(evidence.count == 1)
        #expect(evidence[0].messageID == "m2")
        #expect(evidence[0].text == nil)
    }

    @Test("Capped at 20, keeping the newest")
    func cap() {
        let messages = (0..<25).map { message("m\($0)", from: reported, text: "t\($0)", at: TimeInterval($0)) }
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: Set(messages.map(\.id)), reportedID: reported)
        #expect(evidence.count == 20)
        #expect(evidence.first?.messageID == "m5")
        #expect(evidence.last?.messageID == "m24")
    }

    @Test("Long text and ids are trimmed to the server limits")
    func limits() {
        let long = String(repeating: "x", count: 5000)
        let longID = String(repeating: "i", count: 100)
        let messages = [message(longID, from: reported, text: long, at: 1)]
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: [longID], reportedID: reported)
        #expect(evidence[0].text?.count == 4000)
        #expect(evidence[0].messageID?.count == 64)
    }

    @Test("ReportRequest encodes with the documented keys and ISO-8601 dates")
    func encoding() throws {
        let request = ReportRequest(
            profileID: "p_them",
            reason: .harassment,
            details: nil,
            conversationID: "c1",
            alsoBlock: true,
            evidence: [
                ReportEvidence(messageID: "m1", sentAt: base, fromReported: true, text: "hi", hasPhoto: nil),
                ReportEvidence(messageID: "m2", sentAt: nil, fromReported: false, text: nil, hasPhoto: true),
            ]
        )
        let data = try JSONEncoder.stexx().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["profileID", "reason", "conversationID", "alsoBlock", "evidence"])
        #expect(json["reason"] as? String == "harassment")
        let items = try #require(json["evidence"] as? [[String: Any]])
        #expect(Set(items[0].keys) == ["messageID", "sentAt", "fromReported", "text"])
        #expect(items[0]["sentAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(items[0]["fromReported"] as? Bool == true)
        #expect(Set(items[1].keys) == ["messageID", "fromReported", "hasPhoto"])
        #expect(items[1]["hasPhoto"] as? Bool == true)
    }

    @Test("A report without evidence omits the key")
    func noEvidenceKey() throws {
        let request = ReportRequest(profileID: "p", reason: .spam, details: nil, conversationID: nil, alsoBlock: false, evidence: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.stexx().encode(request)) as? [String: Any])
        #expect(Set(json.keys) == ["profileID", "reason", "alsoBlock"])
    }

    @Test("The mock API records the last report")
    func mockRecords() async throws {
        let api = MockAPIClient(latency: .milliseconds(1))
        let request = ReportRequest(
            profileID: "p01", reason: .spam, details: nil, conversationID: "c-p01", alsoBlock: false,
            evidence: [ReportEvidence(messageID: "m", sentAt: nil, fromReported: true, text: "x", hasPhoto: nil)]
        )
        try await api.report(request)
        #expect(await api.lastReport == request)
    }
}
