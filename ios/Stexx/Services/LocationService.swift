import CoreLocation
import Foundation
import Observation

/// One reading from the location provider. Kept in memory only; never logged
/// or persisted, and fuzzed before it leaves this file.
struct LocationReading: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
}

/// What `LocationService` needs from Core Location, so tests can inject a
/// fake manager.
@MainActor
protocol LocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var onLocation: ((LocationReading) -> Void)? { get set }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func startUpdates()
    func stopUpdates()
    /// Asks for one fresh reading (used for the periodic refresh).
    func requestLocation()
}

/// Uploads the user's coarse location (`PUT /me/location`) while the app is
/// in the foreground and signed in.
///
/// - Asks for when-in-use permission only. Approximate ("reduced") accuracy
///   is fine: everything is snapped to a ~500 m grid by `LocationFuzzer`
///   before upload anyway.
/// - Low frequency: Core Location only reports moves of ~250 m or more, and
///   an upload happens only when the fuzzed grid cell changes or at least
///   15 minutes passed since the last one.
/// - Denied or restricted permission is not an error: nothing is uploaded and
///   the server keeps using its default (dev) or last known location.
@MainActor
@Observable
final class LocationService {
    enum Status: Equatable {
        case idle
        case waitingForPermission
        /// The user said no, or Location Services are off.
        case denied
        /// Screen Time or a device profile doesn't allow location for Stexx.
        case restricted
        case active
    }

    private(set) var status: Status = .idle
    /// The last cell that was successfully uploaded.
    private(set) var lastUploadedCell: FuzzedLocation?
    /// The latest upload attempt failed (offline, server error, rate limit).
    /// Cleared by the next successful upload.
    private(set) var lastUploadFailed = false

    @ObservationIgnored private let manager: any LocationManaging
    @ObservationIgnored private let upload: @Sendable (FuzzedLocation) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let refreshInterval: TimeInterval
    @ObservationIgnored private let failureBackoff: TimeInterval
    @ObservationIgnored private var lastUploadAt: Date?
    @ObservationIgnored private var notBefore: Date?
    @ObservationIgnored private var isUploading = false
    @ObservationIgnored private var queuedReading: LocationReading?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Bumped by `reset()`: an upload still in flight from before (the
    /// previous account) must not record its result afterwards.
    @ObservationIgnored private var generation = 0

    init(
        manager: any LocationManaging,
        refreshInterval: TimeInterval = 15 * 60,
        failureBackoff: TimeInterval = 60,
        now: @escaping @MainActor () -> Date = { Date.now },
        upload: @escaping @Sendable (FuzzedLocation) async throws -> Void
    ) {
        self.manager = manager
        self.refreshInterval = refreshInterval
        self.failureBackoff = failureBackoff
        self.now = now
        self.upload = upload
        manager.onLocation = { [weak self] reading in
            Task { await self?.handle(reading) }
        }
        manager.onAuthorizationChange = { [weak self] status in
            self?.authorizationChanged(status)
        }
    }

    convenience init(api: any APIClient) {
        self.init(manager: SystemLocationManager()) { location in
            try await api.updateLocation(location)
        }
    }

    // MARK: Lifecycle

    /// Starts updates (asking for permission the first time). Call after
    /// sign-in, when the app is in the foreground.
    func start() {
        guard status == .idle else { return }
        apply(manager.authorizationStatus)
    }

    func stop() {
        manager.stopUpdates()
        heartbeat?.cancel()
        heartbeat = nil
        queuedReading = nil
        status = .idle
    }

    /// Forgets upload history, e.g. after signing out.
    func reset() {
        stop()
        generation += 1
        isUploading = false
        lastUploadedCell = nil
        lastUploadFailed = false
        lastUploadAt = nil
        notBefore = nil
    }

    private func authorizationChanged(_ authorization: CLAuthorizationStatus) {
        // Core Location reports the initial status on creation; ignore it
        // (and later changes) while stopped.
        guard status != .idle else { return }
        apply(authorization)
    }

    private func apply(_ authorization: CLAuthorizationStatus) {
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            guard status != .active else { return }
            status = .active
            manager.startUpdates()
            startHeartbeat()
        case .notDetermined:
            status = .waitingForPermission
            // The permission alert deactivates the app: not the app switcher.
            PrivacyCover.shared.expectSystemPrompt()
            manager.requestWhenInUseAuthorization()
        case .denied:
            deny(.denied)
        case .restricted:
            deny(.restricted)
        @unknown default:
            deny(.denied)
        }
    }

    private func deny(_ reason: Status) {
        manager.stopUpdates()
        heartbeat?.cancel()
        heartbeat = nil
        status = reason
    }

    /// Asks for a fresh reading every `refreshInterval` so a stationary user
    /// still refreshes their location now and then.
    private func startHeartbeat() {
        heartbeat?.cancel()
        let interval = refreshInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.manager.requestLocation()
            }
        }
    }

    // MARK: Throttled upload

    /// Whether `cell` should be uploaded now.
    func shouldUpload(_ cell: FuzzedLocation) -> Bool {
        let current = now()
        if let notBefore, current < notBefore { return false }
        if cell != lastUploadedCell { return true }
        guard let lastUploadAt else { return true }
        return current.timeIntervalSince(lastUploadAt) >= refreshInterval
    }

    /// Fuzzes a reading and uploads it if the throttle allows.
    func handle(_ reading: LocationReading) async {
        guard status == .active else { return }
        if isUploading {
            queuedReading = reading
            return
        }
        let cell = LocationFuzzer.fuzz(latitude: reading.latitude, longitude: reading.longitude)
        guard shouldUpload(cell) else { return }

        isUploading = true
        let generation = generation
        let result: Result<Void, any Error>
        do {
            try await upload(cell)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // Signed out (and maybe in as someone else) meanwhile: this upload's
        // outcome says nothing about the current account.
        guard generation == self.generation else { return }
        switch result {
        case .success:
            lastUploadedCell = cell
            lastUploadFailed = false
            lastUploadAt = now()
            notBefore = nil
        case .failure(let error):
            lastUploadFailed = true
            if case .rateLimited(let retryAfter)? = error as? APIError {
                notBefore = now().addingTimeInterval(retryAfter ?? failureBackoff)
            } else {
                notBefore = now().addingTimeInterval(failureBackoff)
            }
        }
        isUploading = false

        if let next = queuedReading {
            queuedReading = nil
            await handle(next)
        }
    }
}

/// `CLLocationManager` configured for coarse, infrequent, foreground-only
/// updates.
@MainActor
final class SystemLocationManager: NSObject, LocationManaging {
    var onLocation: ((LocationReading) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // ~100 m is plenty for a 500 m grid; approximate location also works.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func startUpdates() { manager.startUpdatingLocation() }
    func stopUpdates() { manager.stopUpdatingLocation() }
    func requestLocation() { manager.requestLocation() }
}

extension SystemLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        let reading = LocationReading(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        MainActor.assumeIsolated { onLocation?(reading) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { onAuthorizationChange?(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Transient (no fix yet, denied mid-session is reported via
        // authorization changes). Nothing to do; never log locations.
    }
}
