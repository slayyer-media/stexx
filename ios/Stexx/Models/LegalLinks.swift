import Foundation

/// Public pages the app links to. Shown next to the Stexx+ purchase (App
/// Store Guideline 3.1.2 wants Terms of Use and a Privacy Policy beside an
/// auto-renewing subscription), and meant to be reused by onboarding and
/// Settings.
enum LegalLinks {
    /// Terms of Use (EULA).
    static let terms = URL(string: "https://stexx.gay/terms")!
    /// Privacy Policy.
    static let privacy = URL(string: "https://stexx.gay/privacy")!
    /// Community guidelines.
    static let guidelines = URL(string: "https://stexx.gay/guidelines")!
}
