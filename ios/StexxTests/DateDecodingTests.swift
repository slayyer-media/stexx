import Foundation
import Testing
@testable import Stexx

struct DateDecodingTests {
    private struct Wrapper: Decodable {
        let date: Date
    }

    private func decode(_ string: String) throws -> Date {
        try JSONDecoder.stexx().decode(Wrapper.self, from: Data(#"{"date":"\#(string)"}"#.utf8)).date
    }

    private let reference = Date(timeIntervalSince1970: 1_794_947_400) // 2026-11-17T20:30:00Z

    @Test("Server format without fractional seconds")
    func plain() throws {
        #expect(try decode("2026-11-17T20:30:00Z") == reference)
    }

    @Test("Fractional seconds are accepted")
    func fractional() throws {
        let date = try decode("2026-11-17T20:30:00.250Z")
        #expect(abs(date.timeIntervalSince(reference) - 0.25) < 0.001)
        #expect(abs(try decode("2026-11-17T20:30:00.000Z").timeIntervalSince(reference)) < 0.001)
    }

    @Test("Numeric UTC offsets are accepted")
    func offsets() throws {
        #expect(try decode("2026-11-17T21:30:00+01:00") == reference)
        #expect(abs(try decode("2026-11-17T21:30:00.5+01:00").timeIntervalSince(reference) - 0.5) < 0.001)
    }

    @Test("Garbage is a decoding error, not a crash")
    func invalid() {
        #expect(throws: DecodingError.self) { try decode("yesterday") }
        #expect(throws: DecodingError.self) { try decode("2026-11-17") }
    }

    @Test("Encoding stays plain ISO 8601 and round-trips")
    func roundTrip() throws {
        let data = try JSONEncoder.stexx().encode(["date": reference])
        #expect(String(decoding: data, as: UTF8.self) == #"{"date":"2026-11-17T20:30:00Z"}"#)
        #expect(try JSONDecoder.stexx().decode([String: Date].self, from: data)["date"] == reference)
    }
}
