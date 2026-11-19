import Foundation
import Observation

/// Favorite, tap and block for one profile, with their failure paths: a
/// failed favorite flips the star back, a failed tap re-enables the button,
/// and both say why in `toast`. A failed block never reports success: it
/// sets `blockFailure` so the screen can offer Retry, and the caller only
/// hides the profile when `block` returns `true`.
@MainActor
@Observable
final class ProfileActions {
    var profile: Profile
    private(set) var didTap = false
    private(set) var isSendingTap = false
    private(set) var isBlocking = false
    /// One-line error for the toast.
    var toast: String?
    /// Why the last block failed; non-nil shows the "Couldn't block" alert.
    var blockFailure: String?

    init(profile: Profile) {
        self.profile = profile
    }

    /// Flips the star right away and puts it back if the server says no.
    func toggleFavorite(using api: any APIClient) async {
        let newValue = !profile.isFavorite
        profile.isFavorite = newValue
        do {
            try await api.setFavorite(newValue, profileID: profile.id)
        } catch {
            // Only undo our own flip; a later tap may have changed it again.
            if profile.isFavorite == newValue { profile.isFavorite = !newValue }
            toast = Self.message(
                for: error,
                failedAction: newValue
                    ? String(localized: "Couldn't add to favorites.")
                    : String(localized: "Couldn't remove from favorites.")
            )
        }
    }

    func sendTap(using api: any APIClient) async {
        guard !didTap, !isSendingTap else { return }
        didTap = true
        isSendingTap = true
        defer { isSendingTap = false }
        do {
            try await api.sendTap(to: profile.id)
        } catch {
            didTap = false
            toast = Self.message(for: error, failedAction: String(localized: "Couldn't send the tap."))
        }
    }

    /// Returns `true` only when the server confirmed the block.
    @discardableResult
    func block(using api: any APIClient) async -> Bool {
        guard !isBlocking else { return false }
        isBlocking = true
        defer { isBlocking = false }
        blockFailure = nil
        do {
            try await api.block(profileID: profile.id)
            return true
        } catch {
            blockFailure = Self.message(for: error)
                ?? String(localized: "The block didn't go through.")
            return false
        }
    }

    /// `UserFacingError`, except that a 404 here means the profile itself
    /// is gone (deleted, hidden, or it blocked you; the server doesn't say
    /// which).
    private static func message(for error: any Error, failedAction: String? = nil) -> String? {
        if case APIError.notFound = error {
            return String(localized: "This profile is no longer available.")
        }
        return UserFacingError.message(for: error, failedAction: failedAction)
    }
}
