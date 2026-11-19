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
