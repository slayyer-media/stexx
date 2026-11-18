import Foundation

/// WebSocket connection to `GET /v1/ws` for live chat.
///
/// - Authenticates with `Authorization: Bearer <accessToken>` on the upgrade
///   request (never a query parameter). A 401 on the upgrade refreshes the
///   session once through `SessionCoordinator` and reconnects right away;
///   further 401s in a row back off without refreshing again and give up
///   after a few (see `ReconnectPolicy`).
/// - Reconnects with capped exponential backoff and jitter. The backoff only
///   resets once a connection has stayed up for a while, so a server that
///   accepts and then immediately closes doesn't get hammered. Sends a ping
///   every 25 s so dead connections are noticed.
/// - Decodes `RealtimeEvent`s and hands them to `onEvent` on the main actor;
///   calls `onConnected` on every (re)connect so callers can catch up on
///   events missed while the socket was down.
///
/// Run it only while signed in and in the foreground (`AppServices`).
@MainActor
final class RealtimeClient {
    enum State: Equatable {
        case stopped
        case connecting
        case connected
        case waiting(attempt: Int)
    }

    private(set) var state: State = .stopped
    var onEvent: ((RealtimeEvent) -> Void)?
    /// A connection was established (first ping answered).
    var onConnected: (() -> Void)?

    private let url: URL
    private let urlSession: URLSession
    private let sessions: SessionCoordinator?
    private let refresh: (@Sendable (String) async throws -> Session)?
    private let policyTemplate: ReconnectPolicy
    private var runTask: Task<Void, Never>?
    /// Bumped by `start()`/`stop()`, so a finished or cancelled run never
    /// clears a newer one's state.
    private var generation = 0
    private var socket: URLSessionWebSocketTask?
    private var connectedAt: ContinuousClock.Instant?

    /// - Parameters:
    ///   - sessions: Source of the access token (and refresh on 401).
    ///   - refresh: Calls `/auth/refresh`; used through `sessions` so it
    ///     shares the HTTP client's single-flight refresh.
    init(
        url: URL,
        sessions: SessionCoordinator?,
        urlSession: URLSession = .shared,
        policy: ReconnectPolicy = ReconnectPolicy(),
        refresh: (@Sendable (String) async throws -> Session)?
    ) {
        self.url = url
        self.sessions = sessions
        self.urlSession = urlSession
        self.policyTemplate = policy
        self.refresh = refresh
    }

    var isRunning: Bool { runTask != nil }

    func start() {
        guard runTask == nil, sessions != nil else { return }
        generation += 1
        let generation = generation
        runTask = Task { [weak self] in await self?.run(generation: generation) }
    }

    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectedAt = nil
        state = .stopped
    }

    /// Backoff before reconnect attempt `attempt` (1-based): 1, 2, 4 … 60 s,
    /// with ±20 % jitter so clients don't reconnect in lockstep.
    nonisolated static func backoff(attempt: Int, jitter: Double = .random(in: 0.8...1.2)) -> Duration {
        let base = min(60, pow(2, Double(max(0, attempt - 1))))
        return .milliseconds(Int(base * jitter * 1000))
    }

    // MARK: Connection loop

    private func run(generation: Int) async {
        var policy = policyTemplate
        loop: while !Task.isCancelled {
            guard let sessions, let session = await sessions.currentSession else { break }

            state = .connecting
            connectedAt = nil
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            let task = urlSession.webSocketTask(with: request)
            socket = task
            task.resume()

            let outcome = await receiveLoop(task)
            task.cancel(with: .goingAway, reason: nil)
            if socket === task { socket = nil }
            guard !Task.isCancelled else { break }
            let connectedFor = connectedAt.map { ContinuousClock.now - $0 }
            connectedAt = nil

            var decision = policy.ended(outcome, connectedFor: connectedFor)
            if decision == .refreshAndReconnect {
                guard let refresh else { break }
                do {
                    _ = try await sessions.refreshedSession(rejecting: session, using: refresh)
                    continue
                } catch APIError.unauthorized {
                    // The session is gone; the app signs out.
                    break
                } catch {
                    // Network trouble or a 5xx/429 from /auth/refresh:
                    // transient, so back off and try again.
                    decision = policy.refreshFailed()
                }
            }

            switch decision {
            case .refreshAndReconnect:
                continue
            case .backoff(let attempt):
                state = .waiting(attempt: attempt)
                try? await Task.sleep(for: Self.backoff(attempt: attempt))
            case .giveUp:
                break loop
            }
        }
        // Ended on its own (signed out, gave up): let a later `start()` run
        // again instead of being a no-op.
        if generation == self.generation {
            runTask = nil
            if !Task.isCancelled { state = .stopped }
        }
    }

    /// Reads frames until the socket closes or fails. A ping right after
    /// connecting (and every 25 s) confirms the connection is alive.
    private func receiveLoop(_ task: URLSessionWebSocketTask) async -> ReconnectPolicy.Outcome {
        let pinger = Task { [weak self] in
            var isFirst = true
            while !Task.isCancelled {
                if !isFirst { try? await Task.sleep(for: .seconds(25)) }
                guard !Task.isCancelled else { return }
                guard await Self.ping(task) else {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                if isFirst { self?.markConnected() }
                isFirst = false
            }
        }
        defer { pinger.cancel() }

        while !Task.isCancelled {
            do {
                handle(try await task.receive())
            } catch {
                if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
                    return .unauthorized
                }
                return .closed
            }
        }
        return .closed
    }

    /// The backoff isn't reset here: `ReconnectPolicy` does that once the
    /// connection has stayed up for a while.
    private func markConnected() {
        connectedAt = .now
        state = .connected
        onConnected?()
    }

    private nonisolated static func ping(_ task: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { continuation in
            task.sendPing { error in continuation.resume(returning: error == nil) }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        // Malformed or unknown frames are ignored; never log their content.
        guard let event = try? RealtimeEvent.decode(data) else { return }
        onEvent?(event)
    }
}

/// Decides what the socket does after a connection ends.
///
/// - The backoff grows with every failed or short-lived connection and only
///   resets after a connection stayed up for `stableAfter`.
/// - The first 401 in a row refreshes the session and reconnects at once
///   (the normal "access token expired" case). If the fresh token is
///   rejected too, refreshing again won't help: back off without
///   refreshing, and give up after `maxUnauthorizedStreak` 401s in a row
///   (the next foreground or sign-in starts over).
struct ReconnectPolicy: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case closed, unauthorized }

    enum Decision: Equatable, Sendable {
        case refreshAndReconnect
        case backoff(attempt: Int)
        case giveUp
    }

    var stableAfter: Duration = .seconds(30)
    var maxUnauthorizedStreak = 4
    private(set) var attempt = 0
    private(set) var unauthorizedStreak = 0

    init(stableAfter: Duration = .seconds(30), maxUnauthorizedStreak: Int = 4) {
        self.stableAfter = stableAfter
        self.maxUnauthorizedStreak = maxUnauthorizedStreak
    }

    /// - Parameter connectedFor: How long the connection was up, or `nil`
    ///   if it never got that far (upgrade failed, no ping answer).
    mutating func ended(_ outcome: Outcome, connectedFor: Duration?) -> Decision {
        if let connectedFor {
            unauthorizedStreak = 0
            if connectedFor >= stableAfter { attempt = 0 }
        }
        switch outcome {
        case .closed:
            attempt += 1
            return .backoff(attempt: attempt)
        case .unauthorized:
            unauthorizedStreak += 1
            if unauthorizedStreak > maxUnauthorizedStreak { return .giveUp }
            if unauthorizedStreak == 1 { return .refreshAndReconnect }
            attempt += 1
            return .backoff(attempt: attempt)
        }
    }

    /// The refresh after a 401 failed for a transient reason: back off, and
    /// let the next 401 try refreshing again.
    mutating func refreshFailed() -> Decision {
        unauthorizedStreak = 0
        attempt += 1
        return .backoff(attempt: attempt)
    }
}
