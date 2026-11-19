import CoreGraphics
import Foundation
import SensitiveContentAnalysis

/// What the on-device check made of an incoming chat photo. The server can't
/// see end-to-end encrypted photos, so this runs on the decrypted image,
/// on the phone, and nothing about it leaves the phone.
enum ChatPhotoVerdict: Hashable, Sendable {
    case explicit
    case clean
    /// No analyzer available, or it couldn't decide.
    case unknown
}

/// Checks a decrypted chat photo before it's shown.
protocol ChatPhotoAnalyzer: Sendable {
    func assess(_ image: CGImage) async -> ChatPhotoVerdict
    /// Whether the user turned on Apple's Sensitive Content Warning (or a
    /// parent did, through Communication Safety).
    var systemWarningsEnabled: Bool { get }
}

/// Apple's on-device `SensitiveContentAnalysis`. It only runs for apps with
/// the `com.apple.developer.sensitivecontentanalysis.client` entitlement
/// (granted by Apple on request) and only while the user's Sensitive Content
/// Warning or Communication Safety is on; otherwise `analysisPolicy` is
/// `.disabled` and every photo is `.unknown`. This build doesn't carry the
/// entitlement yet, so for now photos are blurred only by the debug flag.
struct SensitiveContentAnalyzer: ChatPhotoAnalyzer {
    var systemWarningsEnabled: Bool {
        SCSensitivityAnalyzer().analysisPolicy != .disabled
    }

    func assess(_ image: CGImage) async -> ChatPhotoVerdict {
        let analyzer = SCSensitivityAnalyzer()
        guard analyzer.analysisPolicy != .disabled else { return .unknown }
        do {
            return try await analyzer.analyzeImage(image).isSensitive ? .explicit : .clean
        } catch {
            return .unknown
        }
    }
}

#if DEBUG
/// Debug only (`-StexxDebugFlagChatPhotos YES`): flags every incoming photo
/// as explicit, to try and screenshot the blur without the entitlement.
struct FlagEverythingAnalyzer: ChatPhotoAnalyzer {
    var systemWarningsEnabled: Bool { true }
    func assess(_ image: CGImage) async -> ChatPhotoVerdict { .explicit }
}
#endif

/// Whether an incoming chat photo is shown or blurred until tapped.
enum ChatPhotoModeration {
    enum Presentation: Hashable, Sendable {
        case show
        case blurUntilTap
    }

    /// - Own photos are always shown.
    /// - An explicit photo is blurred when the user's "Blur explicit photos"
    ///   is on, or Apple's Sensitive Content Warning is.
    /// - `.unknown` is shown: without an analyzer there's nothing to go on,
    ///   and blurring every photo would make the setting meaningless.
    static func presentation(
        verdict: ChatPhotoVerdict,
        blurExplicitPhotos: Bool,
        systemWarningsEnabled: Bool,
        isOwnPhoto: Bool
    ) -> Presentation {
        guard !isOwnPhoto else { return .show }
        switch verdict {
        case .explicit:
            return blurExplicitPhotos || systemWarningsEnabled ? .blurUntilTap : .show
        case .clean, .unknown:
            return .show
        }
    }

    /// The analyzer the app uses.
    static let analyzer: any ChatPhotoAnalyzer = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "StexxDebugFlagChatPhotos") { return FlagEverythingAnalyzer() }
        #endif
        return SensitiveContentAnalyzer()
    }()
}
