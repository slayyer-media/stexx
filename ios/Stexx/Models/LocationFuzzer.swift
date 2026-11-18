import Foundation

/// Coarsens coordinates on device before they are ever sent to the server.
///
/// Coordinates are snapped to the center of a fixed grid cell rather than
/// jittered randomly: random noise can be averaged away over many updates
/// (and distances trilaterated), while a fixed grid always yields the same
/// answer for the same cell. The server additionally buckets the distances
/// it returns to other members.
enum LocationFuzzer {
    static let defaultCellMeters: Double = 500

    private static let metersPerDegreeLatitude = 111_320.0

    static func fuzz(latitude: Double, longitude: Double, cellMeters: Double = defaultCellMeters) -> FuzzedLocation {
        let latStep = cellMeters / metersPerDegreeLatitude
        let snappedLat = min(90, max(-90, (floor(latitude / latStep) + 0.5) * latStep))

        // Longitude cells use the latitude of the snapped row so every point
        // in the same row shares one cell width.
        let metersPerDegreeLongitude = metersPerDegreeLatitude * max(cos(snappedLat * .pi / 180), 0.01)
        let lonStep = cellMeters / metersPerDegreeLongitude
        var snappedLon = (floor(longitude / lonStep) + 0.5) * lonStep
        if snappedLon > 180 { snappedLon -= 360 }
        if snappedLon < -180 { snappedLon += 360 }

        return FuzzedLocation(latitude: snappedLat, longitude: snappedLon, precisionMeters: cellMeters)
    }
}
