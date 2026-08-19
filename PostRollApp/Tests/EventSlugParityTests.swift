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
            let venue: String
            let name: String
            let date: String
            let slug: String
        }
        let vectors: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        return try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/event_slug.json"))
    }

    func testSwiftBuildsTheSlugPythonRecorded() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 10,
                                    "a gutted fixture would pass vacuously")

        for v in fixture.vectors {
            XCTAssertEqual(EventFolder.name(org: v.org, venue: v.venue,
                                            name: v.name, isoDate: v.date),
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
                       EventFolder.name(org: event.org, venue: event.venue,
                                        name: event.name, isoDate: event.isoDate))
    }

    /// Every route to this name is the SAME name (#689).
    ///
    /// It was spelled three times, twice in this language with two different
    /// sluggers, and they agreed, which is precisely why nobody noticed there
    /// were three. The day one moved, the archive sweep would have stopped
    /// finding the folder the export wrote.
    func testTheExportFolderAndTheArchiveSweepAgreeOnTheName() {
        let event = Event(name: "Sing / Play", org: "", venue: "Kaufman Center",
                          date: Date(timeIntervalSince1970: 1_800_000_000),
                          shootType: .fullShow)
        XCTAssertEqual(ArchiveCleanup.slug(event: event),
                       EventFolder.name(for: event),
                       "the sweep looks for a folder the export does not write")
        XCTAssertEqual(EventExporter.slug("Sing / Play"),
                       EventFolder.slugify("Sing / Play"),
                       "the exporter still slugs text its own way")
    }

    /// An organisation that is there keeps the name it has always had, even
    /// when it slugs away to nothing (#689).
    ///
    /// The folders are on disk. An organisation in a non latin script already
    /// produces a leading underscore, and falling back to the venue for it
    /// would have this side derive a name for a folder Python created months
    /// ago, miss it, and leak it forever.
    func testAnOrganisationThatIsThereIsNeverReplacedByTheVenue() {
        let built = EventFolder.name(org: "!!!", venue: "Roulette",
                                     name: "Hamlet", isoDate: "2026-08-20")
        XCTAssertEqual(built, "_hamlet_2026-08-20")
        XCTAssertFalse(built.contains("roulette"))
    }

    /// And the other direction: nothing is owed a segment it does not have.
    func testNoOrganisationNeverLeavesAnEmptyLeadingSegment() {
        for venue in ["", "   ", "!!!"] {
            let built = EventFolder.name(org: "", venue: venue, name: "Hamlet",
                                         isoDate: "2026-08-20")
            XCTAssertEqual(built, "hamlet_2026-08-20",
                           "a venue of \(venue.debugDescription) produced \(built)")
        }
    }
}
