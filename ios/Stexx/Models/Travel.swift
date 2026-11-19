import Foundation

/// Where travel mode puts you, as this device knows it. Kept on the phone
/// only (`AppState.travel`): the server stores the cell but never returns
/// coordinates, and never receives the name.
struct TravelPlace: Codable, Hashable, Sendable {
    /// The 500 m cell that was sent (already fuzzed). `nil` when travel mode
    /// was turned on from another install.
    var location: FuzzedLocation?
    /// A place name looked up on this device (MapKit), for display only.
    var name: String?
}

/// Where `AppState` keeps the travel place between launches.
protocol TravelPlaceStore: Sendable {
    func load() -> TravelPlace?
    func save(_ place: TravelPlace)
    func clear()
}

/// The app's store: one small file in Application Support, excluded from
/// backups (iCloud and computer) and unreadable until the phone is first
/// unlocked after a restart (`completeUntilFirstUserAuthentication`), like
/// the decrypted chat history. Not in `UserDefaults`, which is a plain,
/// backed-up plist: a planned destination can be sensitive.
struct FileTravelPlaceStore: TravelPlaceStore {
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Travel", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appending(path: "place.json") }

    func load() -> TravelPlace? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TravelPlace.self, from: data)
    }

    func save(_ place: TravelPlace) {
        guard let data = try? JSONEncoder().encode(place) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Best effort: the place is display-only, and the server's
            // `GET /me` still says travel mode is on after a relaunch.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// For previews, screenshots and tests.
final class InMemoryTravelPlaceStore: TravelPlaceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var place: TravelPlace?

    init(_ place: TravelPlace? = nil) { self.place = place }

    func load() -> TravelPlace? { lock.withLock { place } }
    func save(_ place: TravelPlace) { lock.withLock { self.place = place } }
    func clear() { lock.withLock { place = nil } }
}
