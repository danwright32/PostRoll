import XCTest

/// #108: the event folder slug is one rule, satisfied by both languages.
///
/// Python creates the per-event preview folder named by this slug. This side
/// re-derives the same name months later in order to DELETE that folder, from
/// a completely separate implementation, and nothing forced the two to agree.
///
/// Drift is bad in both directions. A slug built differently here misses the
/// folder and leaks it forever; one that happens to collide with another
/// event's deletes files that event is still using.
///
/// `tests/fixtures/event_slug.json` is the contract, and every expected value
/// in it was measured by running Python's `_slug` rather than written by hand,
/// so it cannot record a shape the real function does not produce (L48).
/// `tests/test_event_slug_parity.py` asserts the Python side satisfies it.
final class EventSlugParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Vector: Decodable {
            let _what: String
            let org: String
            let name: String
            let date: String
            let slug: String
        }
        let vectors: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent("tests/fixtures/event_slug.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testSwiftBuildsTheSlugPythonRecorded() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 10,
                                    "a gutted fixture would pass vacuously")

        for v in fixture.vectors {
            XCTAssertEqual(ArchiveCleanup.slug(org: v.org, name: v.name, isoDate: v.date),
                           v.slug,
                           "\(v._what): org \(v.org.debugDescription), "
                           + "name \(v.name.debugDescription)")
        }
    }

    func testTheEventOverloadAgreesWithTheStringOverload() {
        // The sweep calls the Event overload; the fixture exercises the string
        // one. A check whose two sides come from one lookup proves nothing, so
        // the two routes are compared to each other as well (L70).
        var event = Event(name: "Sing / Play", org: "DCINY", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_800_000_000),
                          shootType: .fullShow)
        event.venueContext = ""
        XCTAssertEqual(ArchiveCleanup.slug(event: event),
                       ArchiveCleanup.slug(org: event.org, name: event.name,
                                           isoDate: event.isoDate))
    }
}
