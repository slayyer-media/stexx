import CoreGraphics
import Foundation
import Testing
@testable import Stexx

/// The on-device check on incoming (decrypted) chat photos.
@Suite("Chat photo moderation")
struct ChatPhotoModerationTests {
    @Test("Decision table: own photos always show; explicit blurs with the setting or system warnings; unknown and clean show")
    func decisionTable() {
        typealias M = ChatPhotoModeration
        for verdict in [ChatPhotoVerdict.explicit, .clean, .unknown] {
            for blur in [true, false] {
                for system in [true, false] {
                    #expect(M.presentation(verdict: verdict, blurExplicitPhotos: blur, systemWarningsEnabled: system, isOwnPhoto: true) == .show)
                }
            }
        }
        #expect(M.presentation(verdict: .explicit, blurExplicitPhotos: true, systemWarningsEnabled: false, isOwnPhoto: false) == .blurUntilTap)
        #expect(M.presentation(verdict: .explicit, blurExplicitPhotos: false, systemWarningsEnabled: true, isOwnPhoto: false) == .blurUntilTap)
        #expect(M.presentation(verdict: .explicit, blurExplicitPhotos: true, systemWarningsEnabled: true, isOwnPhoto: false) == .blurUntilTap)
        #expect(M.presentation(verdict: .explicit, blurExplicitPhotos: false, systemWarningsEnabled: false, isOwnPhoto: false) == .show)
        for blur in [true, false] {
            for system in [true, false] {
                #expect(M.presentation(verdict: .unknown, blurExplicitPhotos: blur, systemWarningsEnabled: system, isOwnPhoto: false) == .show)
                #expect(M.presentation(verdict: .clean, blurExplicitPhotos: blur, systemWarningsEnabled: system, isOwnPhoto: false) == .show)
            }
        }
    }

    @Test("Without the entitlement (simulator, this build) Apple's analyzer is off: .unknown, warnings off")
    func sensitiveContentAnalyzerDisabled() async throws {
        let analyzer = SensitiveContentAnalyzer()
        #expect(!analyzer.systemWarningsEnabled)
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        #expect(await analyzer.assess(image) == .unknown)
    }

    @Test("Without the debug launch argument the app uses Apple's analyzer")
    func defaultAnalyzer() {
        #expect(!UserDefaults.standard.bool(forKey: "StexxDebugFlagChatPhotos"))
        #expect(ChatPhotoModeration.analyzer is SensitiveContentAnalyzer)
    }
}
