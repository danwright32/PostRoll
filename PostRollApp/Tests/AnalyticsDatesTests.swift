import XCTest

/// Pins the lenient date decoding contract (issue #1): Python emits naive
/// local timestamps, date only strings, and Z suffixed UTC. Swift's strict
/// .iso8601 strategy rejects the first two, which silently broke the
/// Insights CSV import. Every analytics decode must use the lenient
/// strategy, and these tests pin every shape Python actually produces.
final class AnalyticsDatesTests: XCTestCase {
    private struct Box: Codable { let d: Date }

    private func decode(_ raw: String) throws -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = AnalyticsDates.lenientDecoding
        let json = Data("{\"d\": \"\(raw)\"}".utf8)
        return try decoder.decode(Box.self, from: json).d
    }

    func testNaiveMetaImportTimestamp() throws {
        // import_meta_csv writes datetime.isoformat() with no timezone
        _ = try decode("2026-01-15T09:00:00")
    }

    func testDateOnlyInsightRange() throws {
        // analyze_posts can emit date only strings for date_range_start
        _ = try decode("2026-06-11")
    }

    func testUTCGeneratedAt() throws {
        let date = try decode("2026-06-11T14:00:00Z")
        XCTAssertEqual(date.timeIntervalSince1970, 1781186400, accuracy: 1)
    }

    func testExplicitOffset() throws {
        let utc = try decode("2026-06-11T14:00:00Z")
        let offset = try decode("2026-06-11T16:00:00+02:00")
        XCTAssertEqual(utc, offset)
    }

    func testFractionalSeconds() throws {
        _ = try decode("2026-06-11T14:00:00.123Z")
    }

    func testGarbageStillThrows() {
        XCTAssertThrowsError(try decode("not a date"))
    }

    func testStrictISO8601RejectsNaiveForm() {
        // Documents the original bug: strict .iso8601 cannot decode what
        // Python writes. If this ever starts passing, the lenient strategy
        // may no longer be necessary, but until then it is load bearing.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = Data("{\"d\": \"2026-01-15T09:00:00\"}".utf8)
        XCTAssertThrowsError(try decoder.decode(Box.self, from: json))
    }
}
