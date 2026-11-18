import Foundation
import Testing
@testable import Stexx

struct LocationFuzzerTests {
    /// Equirectangular approximation; plenty for sub-kilometer distances.
    private func meters(from a: (Double, Double), to b: (Double, Double)) -> Double {
        let meanLat = (a.0 + b.0) / 2 * .pi / 180
        let dLat = (b.0 - a.0) * 111_320
        let dLon = (b.1 - a.1) * 111_320 * cos(meanLat)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    @Test("Points in the same cell map to the same coordinates")
    func sameCellIsStable() {
        let cell = 500.0
        let a = LocationFuzzer.fuzz(latitude: 10.0011, longitude: 20.0011, cellMeters: cell)
        let b = LocationFuzzer.fuzz(latitude: 10.0012, longitude: 20.0012, cellMeters: cell)
        #expect(a == b)
        #expect(a.precisionMeters == cell)
    }

    @Test("Fuzzed point stays within one cell of the original", arguments: [
        (0.0, 0.0), (10.0011, 20.0011), (-33.9, 151.2), (64.1, -21.9), (89.99, 179.99),
    ])
    func staysClose(latitude: Double, longitude: Double) {
        let fuzzed = LocationFuzzer.fuzz(latitude: latitude, longitude: longitude)
        let distance = meters(from: (latitude, longitude), to: (fuzzed.latitude, fuzzed.longitude))
        // Half the cell diagonal is ~354 m for 500 m cells.
        #expect(distance <= LocationFuzzer.defaultCellMeters * 0.75)
    }

    @Test("Output never reveals the input's extra precision")
    func discardsPrecision() {
        let a = LocationFuzzer.fuzz(latitude: 10.00111111, longitude: 20.00111111)
        let b = LocationFuzzer.fuzz(latitude: 10.00122222, longitude: 20.00122222)
        #expect(a.latitude == b.latitude)
        #expect(a.longitude == b.longitude)
    }
}
