import Foundation
import Testing
@testable import Stexx

@Suite("Distance formatting")
struct FormattingTests {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    @Test("Imperial shows miles to one decimal, never fractional feet")
    func imperial() {
        #expect(StexxFormat.distance(100, locale: us) == "0.1 mi")
        #expect(StexxFormat.distance(500, locale: us) == "0.3 mi")
        #expect(StexxFormat.distance(1600, locale: us) == "1 mi")
        #expect(StexxFormat.distance(25_000, locale: us) == "16 mi")
        #expect(!StexxFormat.distance(500, locale: us).contains("ft"))
    }

    @Test("Metric rounds to 100 m, then 0.1 km")
    func metric() {
        #expect(StexxFormat.distance(40, locale: de) == "100 m")
        #expect(StexxFormat.distance(500, locale: de) == "500 m")
        #expect(StexxFormat.distance(1500, locale: de) == "1,5 km")
    }
}
