import CoreLocation
import Foundation
import Testing
@testable import Stexx

@MainActor
final class FakeLocationManager: LocationManaging {
    var authorizationStatus: CLAuthorizationStatus
    var onLocation: ((LocationReading) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var isUpdating = false

    init(status: CLAuthorizationStatus) {
        authorizationStatus = status
    }

    func requestWhenInUseAuthorization() { authorizationRequests += 1 }
    func startUpdates() { isUpdating = true }
    func stopUpdates() { isUpdating = false }
    func requestLocation() {}

    /// Simulates the user answering the permission prompt.
    func answer(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        onAuthorizationChange?(status)
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

actor UploadRecorder {
    private(set) var uploads: [FuzzedLocation] = []
    var failure: (any Error)?

    func record(_ location: FuzzedLocation) throws {
        if let failure {
            self.failure = nil
            throw failure
        }
        uploads.append(location)
    }

    func fail(next error: any Error) { failure = error }
}

@MainActor
struct LocationServiceTests {
    private let clock = TestClock()
    private let recorder = UploadRecorder()

    private func makeService(_ manager: FakeLocationManager) -> LocationService {
        let clock = clock
        let recorder = recorder
        return LocationService(manager: manager, now: { clock.now }) { location in
            try await recorder.record(location)
        }
    }

    /// The center of the grid cell around a point, plus a nudge that stays
    /// inside the same cell.
    private func reading(_ latitude: Double, _ longitude: Double, nudge: Double = 0) -> LocationReading {
        let cell = LocationFuzzer.fuzz(latitude: latitude, longitude: longitude)
        return LocationReading(latitude: cell.latitude + nudge, longitude: cell.longitude + nudge)
    }

    @Test("Uploads only when the cell changes or every 15 minutes")
    func throttling() async {
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let service = makeService(manager)
        service.start()
        #expect(service.status == .active)
        #expect(manager.isUpdating)

        await service.handle(reading(52.52, 13.405))
        #expect(await recorder.uploads.count == 1)

        // Moving within the same cell a minute later: nothing new to say.
        clock.advance(60)
        await service.handle(reading(52.52, 13.405, nudge: 0.0005))
        #expect(await recorder.uploads.count == 1)

        // A different cell: upload right away.
        clock.advance(60)
        await service.handle(reading(52.60, 13.405))
        #expect(await recorder.uploads.count == 2)

        // Same cell, but 15 minutes since the last upload: refresh.
        clock.advance(14 * 60)
        await service.handle(reading(52.60, 13.405))
        #expect(await recorder.uploads.count == 2)
        clock.advance(60)
        await service.handle(reading(52.60, 13.405))
        #expect(await recorder.uploads.count == 3)
    }

    @Test("Only fuzzed coordinates are uploaded")
    func uploadsFuzzedCells() async {
        let service = makeService(FakeLocationManager(status: .authorizedWhenInUse))
        service.start()
        await service.handle(LocationReading(latitude: 52.520_123_4, longitude: 13.405_678_9))
        let upload = await recorder.uploads.first
        #expect(upload == LocationFuzzer.fuzz(latitude: 52.520_123_4, longitude: 13.405_678_9))
        #expect(upload?.precisionMeters == LocationFuzzer.defaultCellMeters)
    }

    @Test("Denied permission is handled quietly")
    func denied() async {
        let manager = FakeLocationManager(status: .denied)
        let service = makeService(manager)
        service.start()
        #expect(service.status == .denied)
        #expect(!manager.isUpdating)
        await service.handle(reading(52.52, 13.405))
        #expect(await recorder.uploads.isEmpty)
    }

    @Test("Asks for when-in-use permission once, then starts")
    func asksForPermission() async {
        let manager = FakeLocationManager(status: .notDetermined)
        let service = makeService(manager)
        service.start()
        #expect(service.status == .waitingForPermission)
        #expect(manager.authorizationRequests == 1)
        #expect(!manager.isUpdating)

        manager.answer(.authorizedWhenInUse)
        #expect(service.status == .active)
        #expect(manager.isUpdating)

        service.stop()
        #expect(service.status == .idle)
        #expect(!manager.isUpdating)
        // Changes while stopped are ignored.
        manager.answer(.authorizedWhenInUse)
        #expect(service.status == .idle)
    }

    @Test("A 429 defers the next upload by Retry-After")
    func rateLimitBackoff() async {
        let service = makeService(FakeLocationManager(status: .authorizedWhenInUse))
        service.start()
        await recorder.fail(next: APIError.rateLimited(retryAfter: 120))
        await service.handle(reading(52.52, 13.405))
        #expect(await recorder.uploads.isEmpty)

        clock.advance(60)
        await service.handle(reading(52.60, 13.405))
        #expect(await recorder.uploads.isEmpty)

        clock.advance(61)
        await service.handle(reading(52.60, 13.405))
        #expect(await recorder.uploads.count == 1)
    }
}
