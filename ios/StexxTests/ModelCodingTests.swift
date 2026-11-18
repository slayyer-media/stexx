import Foundation
import Testing
@testable import Stexx

struct ModelCodingTests {
    @Test("Profile decodes from the documented API shape")
    func decodesProfile() throws {
        let json = Data("""
        {
          "id": "p_7f3a",
          "displayName": "Eigenbro",
          "age": 29,
          "pronouns": "he/him",
          "headline": "Will explain Fourier transforms on the first date",
          "about": null,
          "heightCm": 182,
          "position": "versatile",
          "lookingFor": ["dates", "chat"],
          "tags": ["Math", "Synths"],
          "photos": [{ "id": "ph_1", "url": "https://media.stexx.gay/ph_1.jpg", "isExplicit": false }],
          "distanceMeters": 300,
          "isOnline": true,
          "lastActiveAt": "2026-11-17T20:30:00Z",
          "isFavorite": false
        }
        """.utf8)

        let profile = try JSONDecoder.stexx().decode(Profile.self, from: json)
        #expect(profile.displayName == "Eigenbro")
        #expect(profile.position == .versatile)
        #expect(profile.lookingFor == [.dates, .chat])
        #expect(profile.primaryPhotoURL?.host() == "media.stexx.gay")
        #expect(profile.nameAndAge == "Eigenbro, 29")
    }

    @Test("Messages round-trip through the API coders")
    func messageRoundTrip() throws {
        let message = Message(
            id: "m1",
            conversationID: "c1",
            senderID: "me",
            text: "hi :)",
            attachment: Message.Attachment(kind: .photo, url: nil, isViewOnce: true),
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            status: .delivered,
            expiresAt: nil,
            clientID: "client-1"
        )
        let data = try JSONEncoder.stexx().encode(message)
        let decoded = try JSONDecoder.stexx().decode(Message.self, from: data)
        #expect(decoded == message)
    }

    @Test("Advanced filters are detected")
    func advancedFilters() {
        var query = NearbyQuery()
        query.onlineOnly = true
        #expect(!query.usesAdvancedFilters)
        query.positions = [.top]
        #expect(query.usesAdvancedFilters)
    }

    @Test("Photos the server labelled explicit are left out of the public photos")
    func publicPhotosSkipExplicit() throws {
        let json = Data("""
        [{ "id": "ph_1", "url": "https://media.stexx.gay/a.jpg", "isExplicit": true },
         { "id": "ph_2", "url": "https://media.stexx.gay/b.jpg", "isExplicit": false }]
        """.utf8)
        var profile = MockData.me
        profile.photos = try JSONDecoder.stexx().decode([Photo].self, from: json)
        #expect(profile.photos.map(\.isExplicit) == [true, false])
        #expect(profile.publicPhotos.map(\.id) == ["ph_2"])
    }
}
