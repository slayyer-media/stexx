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

    // MARK: Evidence photos

    @Test("photoID encodes next to hasPhoto, and is omitted when absent")
    func photoIDEncoding() throws {
        let request = ReportRequest(
            profileID: "p_them", reason: .harassment, details: nil, conversationID: "c1", alsoBlock: false,
            evidence: [
                ReportEvidence(messageID: "m1", sentAt: nil, fromReported: true, text: nil, hasPhoto: true, photoID: "ph_1"),
                ReportEvidence(messageID: "m2", sentAt: nil, fromReported: true, text: nil, hasPhoto: true),
            ]
        )
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.stexx().encode(request)) as? [String: Any])
        let items = try #require(json["evidence"] as? [[String: Any]])
        #expect(Set(items[0].keys) == ["messageID", "fromReported", "hasPhoto", "photoID"])
        #expect(items[0]["photoID"] as? String == "ph_1")
        #expect(items[0]["hasPhoto"] as? Bool == true)
        #expect(Set(items[1].keys) == ["messageID", "fromReported", "hasPhoto"])
        #expect(try JSONDecoder.stexx().decode(ReportRequest.self, from: JSONEncoder.stexx().encode(request)) == request)
    }

    @Test("Ticked photos get a photoID: at most 10, the reported person's first; unloadable ones keep hasPhoto only")
    func attachingPhotos() async throws {
        var messages = (0..<8).map { message("t\($0)", from: reported, photo: true, at: TimeInterval($0)) }
        messages += (0..<5).map { message("y\($0)", from: me, photo: true, at: TimeInterval(100 + $0)) }
        messages.append(message("text", from: reported, text: "no photo", at: 200))
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: Set(messages.map(\.id)), reportedID: reported)
        let uploads = CallLog()
        let result = await ReportEvidence.attachingPhotos(
            to: evidence,
            messages: messages,
            load: { message in message.id == "t3" ? nil : Data(message.id.utf8) },
            upload: { data in
                let id = "ph-" + String(decoding: data, as: UTF8.self)
                await uploads.record(id)
                return id
            }
        )
        #expect(result.count == evidence.count)
        #expect(result.filter { $0.photoID != nil }.count == 10)
        #expect(await uploads.entries.count == 10)
        // All of theirs that could load (t3 couldn't), then the newest of the reporter's own.
        let theirs = result.filter { $0.fromReported && $0.hasPhoto == true }
        #expect(theirs.filter { $0.photoID != nil }.count == 7)
        #expect(result.first { $0.messageID == "t3" }?.photoID == nil)
        #expect(result.first { $0.messageID == "t3" }?.hasPhoto == true)
        #expect(Set(result.filter { !$0.fromReported && $0.photoID != nil }.compactMap(\.messageID)) == ["y4", "y3", "y2"])
        for item in result where item.photoID != nil {
            #expect(item.photoID == "ph-\(item.messageID ?? "")")
        }
        #expect(result.first { $0.messageID == "text" }?.photoID == nil)
    }

    @Test("A failed upload leaves the item without a photoID; the report still goes out")
    func failedUpload() async {
        let messages = [message("m1", from: reported, photo: true, at: 1)]
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: ["m1"], reportedID: reported)
        let result = await ReportEvidence.attachingPhotos(
            to: evidence, messages: messages,
            load: { _ in Data([1]) },
            upload: { _ in throw APIError.server(status: 409, message: "limit") }
        )
        #expect(result == evidence)
    }

    @Test("A retry reuses the photos an earlier attempt uploaded and uploads only the rest")
    func retryReusesUploads() async {
        let messages = (1...3).map { message("m\($0)", from: reported, photo: true, at: TimeInterval($0)) }
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: Set(messages.map(\.id)), reportedID: reported)
        let first = CallLog()
        let attempt1 = await ReportEvidence.attachingPhotos(
            to: evidence, messages: messages,
            load: { Data($0.id.utf8) },
            upload: { data in
                let id = String(decoding: data, as: UTF8.self)
                await first.record(id)
                if id == "m2" { throw URLError(.networkConnectionLost) }
                return "ph-" + id
            }
        )
        #expect(Set(await first.entries) == ["m1", "m2", "m3"])
        let known = ReportEvidence.uploadedPhotoIDs(in: attempt1)
        #expect(known == ["m1": "ph-m1", "m3": "ph-m3"])

        let second = CallLog()
        let attempt2 = await ReportEvidence.attachingPhotos(
            to: evidence, messages: messages, reusing: known,
            load: { Data($0.id.utf8) },
            upload: { data in
                let id = String(decoding: data, as: UTF8.self)
                await second.record(id)
                return "ph-" + id
            }
        )
        #expect(await second.entries == ["m2"])
        #expect(attempt2.map(\.photoID) == ["ph-m1", "ph-m2", "ph-m3"])
    }

    @Test("attachment_limit (409) stops further uploads; those items keep hasPhoto, reused photos still go")
    func attachmentLimit() async {
        let messages = (1...4).map { message("m\($0)", from: reported, photo: true, at: TimeInterval($0)) }
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: Set(messages.map(\.id)), reportedID: reported)
        let uploads = CallLog()
        let result = await ReportEvidence.attachingPhotos(
            to: evidence, messages: messages, reusing: ["m1": "ph-old"],
            load: { Data($0.id.utf8) },
            upload: { data in
                await uploads.record(String(decoding: data, as: UTF8.self))
                throw APIError.server(status: 409, message: "You have too many photos waiting to be sent (max 10).")
            }
        )
        // Newest first: m4 hits the limit; m3 and m2 aren't tried.
        #expect(await uploads.entries == ["m4"])
        #expect(result.map(\.hasPhoto) == [true, true, true, true])
        #expect(result.map(\.photoID) == ["ph-old", nil, nil, nil])
    }

    @Test("With the mock: a retry after a failed report sends the first attempt's uploads, uploading nothing new")
    func mockRetry() async throws {
        let api = MockAPIClient(latency: .milliseconds(1))
        let messages = (1...2).map { message("m\($0)", from: reported, photo: true, at: TimeInterval($0)) }
        let evidence = ReportEvidence.from(messages: messages, selectedIDs: Set(messages.map(\.id)), reportedID: reported)
        let uploads = CallLog()
        let upload: @Sendable (Data) async throws -> Photo.ID = { data in
            await uploads.record("upload")
            return try await api.uploadAttachment(jpegData: data).id
        }
        let attempt1 = await ReportEvidence.attachingPhotos(to: evidence, messages: messages, load: { _ in Data([0xFF, 0xD8, 0xFF]) }, upload: upload)
        // The report itself failed (say, offline); the user taps Send again.
        let attempt2 = await ReportEvidence.attachingPhotos(
            to: evidence, messages: messages, reusing: ReportEvidence.uploadedPhotoIDs(in: attempt1),
            load: { _ in Data([0xFF, 0xD8, 0xFF]) }, upload: upload
        )
        #expect(await uploads.count("upload") == 2)
        #expect(attempt2 == attempt1)
        let request = ReportRequest(profileID: "p01", reason: .spam, details: nil, conversationID: "c-p01", alsoBlock: false, evidence: attempt2)
        try await api.report(request)
        #expect(await api.lastReport?.evidence?.compactMap(\.photoID).count == 2)
    }

    @Test("The mock accepts evidence photos from your own uploads, once each")
    func mockEvidencePhotos() async throws {
        let api = MockAPIClient(latency: .milliseconds(1))
        let upload = try await api.uploadAttachment(jpegData: Data([0xFF, 0xD8, 0xFF]))
        let request = ReportRequest(
            profileID: "p01", reason: .spam, details: nil, conversationID: "c-p01", alsoBlock: false,
            evidence: [ReportEvidence(messageID: "m", sentAt: nil, fromReported: true, text: nil, hasPhoto: true, photoID: upload.id)]
        )
        try await api.report(request)
        #expect(await api.lastReport == request)
        // Consumed by the report.
        await #expect(throws: APIError.notFound) { try await api.report(request) }

        let second = try await api.uploadAttachment(jpegData: Data([0xFF, 0xD8, 0xFF]))
        let twice = ReportEvidence(messageID: "m", sentAt: nil, fromReported: true, text: nil, hasPhoto: true, photoID: second.id)
        await #expect(throws: APIError.self) {
            try await api.report(ReportRequest(profileID: "p01", reason: .spam, details: nil, conversationID: nil, alsoBlock: false, evidence: [twice, twice]))
        }
    }
}
