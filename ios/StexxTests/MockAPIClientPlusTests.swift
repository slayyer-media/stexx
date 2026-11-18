import Foundation
import Testing
@testable import Stexx

struct MockAPIClientPlusTests {
    @Test("Mock Plus endpoints gate on the subscription")
    func plusGating() async throws {
        let api = MockAPIClient(latency: .zero)
        #expect(try await api.subscriptionStatus() == .inactive)
        await #expect(throws: APIError.requiresPlus) { try await api.startBoost() }

        let status = try await api.submitAppleTransaction(signedTransaction: "jws")
        #expect(status.isActive)
        let boost = try await api.startBoost()
        #expect(boost.endsAt > .now)
        try await api.setTravelLocation(nil)
    }

    @Test("Photos can be deleted and reordered")
    func photoManagement() async throws {
        let api = MockAPIClient(latency: .zero)
        let a = try await api.uploadPhoto(jpegData: Data([0xFF, 0xD8, 0xFF]))
        let b = try await api.uploadPhoto(jpegData: Data([0xFF, 0xD8, 0xFF]))
        let c = try await api.uploadPhoto(jpegData: Data([0xFF, 0xD8, 0xFF]))

        try await api.deletePhoto(id: b.id)
        let reordered = try await api.reorderPhotos([c.id, a.id])
        #expect(reordered.map(\.id) == [c.id, a.id])
        #expect(try await api.fetchMe().photos.map(\.id) == [c.id, a.id])
        await #expect(throws: (any Error).self) { try await api.reorderPhotos([a.id]) }
    }

    @Test("Photo messages carry the uploaded photo")
    func photoMessage() async throws {
        let api = MockAPIClient(latency: .zero)
        let conversation = try await api.openConversation(with: "p03")
        let photo = try await api.uploadPhoto(jpegData: Data([0xFF, 0xD8, 0xFF]))
        let message = try await api.send(
            MessageDraft(clientID: "photo-1", attachmentPhotoID: photo.id, expiresAfterSeconds: 60),
            in: conversation.id
        )
        #expect(message.attachment?.kind == .photo)
        #expect(message.attachment?.url == photo.url)
    }
}

/// Checks the bundled `Stexx.storekit` (the file the "Stexx Local" scheme
/// uses) defines the product the app sells.
struct StoreKitConfigurationTests {
    private final class BundleToken {}

    @Test("Stexx+ monthly is a $9.99 auto-renewable monthly subscription")
    func plusProduct() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Stexx", withExtension: "storekit"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
        let subscriptions = groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
        let plus = try #require(subscriptions.first { $0["productID"] as? String == PlusProduct.monthlyID })
        #expect(plus["type"] as? String == "RecurringSubscription")
        #expect(plus["recurringSubscriptionPeriod"] as? String == "P1M")
        #expect(plus["displayPrice"] as? String == "9.99")
        #expect(PurchaseService.productIDs == [PlusProduct.monthlyID])
    }
}
