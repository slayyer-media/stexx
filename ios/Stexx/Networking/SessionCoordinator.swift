import Foundation

/// Owns the stored session for the live client and makes sure a rejected
/// access token is refreshed exactly once, however many requests hit 401 at
/// the same time (single flight). Everyone waiting gets the same new session.
///
/// A refresh is tied to the session it started from: if the user signs out,
/// or another account signs in, while `/auth/refresh` is in flight, the
/// result is dropped instead of being written back to the store, and a
/// request made for one account is never retried with another's token.
actor SessionCoordinator {
    private let store: any SessionStore
    private let hooks: APIClientHooks
    /// The refresh in flight, keyed by the refresh token it spends.
    private var inFlight: (refreshToken: String, task: Task<Session, any Error>)?

    init(store: any SessionStore, hooks: APIClientHooks = APIClientHooks()) {
        self.store = store
        self.hooks = hooks
    }

    var currentSession: Session? { store.load() }

    func accessToken() -> String? {
        store.load()?.accessToken
    }

    /// Returns a session for the same account as `rejected` whose access
    /// token differs from the rejected one, refreshing via `refresh` if
    /// nobody has done so yet.
    ///
    /// - Parameter rejected: The session the failed request was sent with
    ///   (`nil` if it had none).
    /// - Throws: `APIError.unauthorized` when the refresh token itself is
    ///   rejected (after clearing the session and calling `sessionExpired`),
    ///   when nothing is stored, or when the session changed underneath the
    ///   request (sign-out, another account). Network errors are rethrown
    ///   without signing out.
    func refreshedSession(
        rejecting rejected: Session?,
        using refresh: @escaping @Sendable (String) async throws -> Session
    ) async throws -> Session {
        guard let current = store.load() else {
            // Nothing to refresh with. Make sure the app agrees it's signed
            // out (e.g. the store lost the session).
            await expire()
            throw APIError.unauthorized
        }
        // Sent without a session, or for an account that's no longer the
        // current one: never hand it this account's tokens.
        guard let rejected, rejected.userID == current.userID else {
            throw APIError.unauthorized
        }
        // Someone else already rotated the token while our request was in flight.
        if current.accessToken != rejected.accessToken {
            return current
        }
        guard let refreshToken = current.refreshToken else {
            await expire()
            throw APIError.unauthorized
        }

        if let inFlight, inFlight.refreshToken == refreshToken {
            do {
                return try await inFlight.task.value
            } catch let error as APIError where error.isRejectedCredential {
                throw APIError.unauthorized
            } catch is Superseded {
                throw APIError.unauthorized
            }
        }

        let userID = current.userID
        let store = self.store
        let task = Task<Session, any Error> {
            let session = try await refresh(refreshToken)
            // Only write it back if the session we refreshed is still the
            // stored one; sign-out or another sign-in wins.
            guard store.replace(userID: userID, refreshToken: refreshToken, with: session) else {
                throw Superseded()
            }
            return session
        }
        inFlight = (refreshToken, task)
        defer {
            if inFlight?.task == task { inFlight = nil }
        }

        do {
            let session = try await task.value
            await hooks.sessionRefreshed(session)
            return session
        } catch let error as APIError where error.isRejectedCredential {
            // Sign out only if the rejected refresh token is still the
            // stored one (not if the user already signed out or switched).
            if store.replace(userID: userID, refreshToken: refreshToken, with: nil) {
                await hooks.sessionExpired()
            }
            throw APIError.unauthorized
        } catch is Superseded {
            throw APIError.unauthorized
        }
    }

    /// Clears the session without telling the server (it's already invalid)
    /// and tells the app, which ignores it if it's already signed out.
    private func expire() async {
        store.clear()
        await hooks.sessionExpired()
    }

    /// The refreshed session belonged to a session that's gone.
    private struct Superseded: Error {}
}

/// Revokes a session on the server after the user signed out locally.
enum SessionRevocation {
    /// Calls `logout` (which refreshes an expired access token with the
    /// session's own refresh token), retrying transient failures a few
    /// times. Returns whether the server confirmed the session is gone.
    @discardableResult
    static func revoke(
        _ session: Session,
        using api: any APIClient,
        attempts: Int = 4,
        delay: @escaping @Sendable (Int) -> Duration = { attempt in .seconds(2 << min(attempt, 4)) }
    ) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            do {
                try await api.logout(session)
                return true
            } catch let error as APIError {
                switch error {
                // The tokens are already invalid: nothing left to revoke.
                case .unauthorized, .notFound: return true
                case .rateLimited, .server, .e2e, .invalidResponse: break
                case .requiresPlus: return false
                }
            } catch is CancellationError {
                return false
            } catch {
                // Network error: retry.
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: delay(attempt))
            }
        }
        return false
    }
}

private extension APIError {
    /// Errors from `/auth/refresh` that mean the refresh token is no good.
    var isRejectedCredential: Bool {
        switch self {
        case .unauthorized, .notFound: true
        case .server(let status, _): status == 400 || status == 403
        default: false
        }
    }
}
