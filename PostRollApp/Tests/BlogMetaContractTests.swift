import XCTest

/// #283: the SEO description and details block are deterministic, and shared.
///
/// Every generated post ships `<meta name="description" content="">`, so
/// Squarespace falls back to `og:description` and the summary crawlers see is
/// the opening prose. Good writing, useless as a summary.
///
/// Both strings are pure functions of the event, computed here and mirrored in
/// `postroll/blog_meta.py`. `tests/fixtures/blog_meta.json` states the cases
/// once so neither side can drift; `tests/test_blog_meta.py` asserts the Python
/// half against the same file.
final class BlogMetaContractTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Facts: Decodable {
            let name: String
            let org: String
            let venue: String
            let venue_context: String
            let date: String
            let shoot_type: String
            let event_url: String
        }
        struct Vector: Decodable {
            let _what: String
            let event: Facts
            let description: String
            let details: String
        }
        struct DateCase: Decodable {
            let iso: String
            let formatted: String
        }
        let description_min: Int
        let description_max: Int
        let vectors: [Vector]
        /// #1106: every valid ISO date the two halves must render identically.
        let dates: [DateCase]
        /// The dates neither half can read, where the two deliberately differ.
        let unreadable_dates: [String]
        /// #1106: the shoot type map, written once instead of twice.
        let shoot_types: [String: String]
    }

    /// The characters the global writing rule bans, as escapes so this file has
    /// nothing for the pre-push style hook to catch.
    private static let bannedDashes = ["\u{2014}", "\u{2013}"]

    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/blog_meta.json"))
    }

    func testSwiftDescriptionSatisfiesTheSharedContract() throws {
        let fixture = try fixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 9,
                                    "a gutted fixture would pass vacuously")
        for v in fixture.vectors {
            XCTAssertEqual(
                BlogMeta.seoDescription(name: v.event.name, org: v.event.org,
                                        venue: v.event.venue,
                                        venueContext: v.event.venue_context,
                                        isoDate: v.event.date,
                                        shootType: v.event.shoot_type),
                v.description, v._what)
        }
    }

    func testSwiftDetailsSatisfyTheSharedContract() throws {
        for v in try fixture().vectors {
            XCTAssertEqual(
                BlogMeta.detailsBlock(name: v.event.name, org: v.event.org,
                                      venue: v.event.venue,
                                      venueContext: v.event.venue_context,
                                      isoDate: v.event.date,
                                      shootType: v.event.shoot_type,
                                      eventURL: v.event.event_url),
                v.details, v._what)
        }
    }

    func testEveryDescriptionLandsInsideSquarespacesBand() throws {
        // Outside 50 to 300 the field is either refused or truncated
        // mid-sentence, and neither is visible from inside the app.
        let fixture = try fixture()
        for v in fixture.vectors {
            let length = v.description.count
            XCTAssertGreaterThanOrEqual(length, fixture.description_min, v._what)
            XCTAssertLessThanOrEqual(length, fixture.description_max, v._what)
        }
    }

    func testNoBannedDashSurvivesIntoEitherString() throws {
        // The style hook reads source, never runtime output, so an event name
        // Dan typed with an em dash would otherwise ship one into the metadata.
        for v in try fixture().vectors {
            for dash in Self.bannedDashes {
                XCTAssertFalse(v.description.contains(dash), v._what)
                XCTAssertFalse(v.details.contains(dash), v._what)
            }
        }
    }

    // MARK: - Failure paths

    func testAnOverLongNameIsBroughtInsideTheBandAtAWordBoundary() {
        let name = "A " + String(repeating: "Very Long ", count: 60) + "Program"
        let text = BlogMeta.seoDescription(
            name: name, org: "Distinguished Concerts International New York",
            venue: "Carnegie Hall", venueContext: "Stern Auditorium",
            isoDate: "2026-10-18", shootType: "performance")
        XCTAssertLessThanOrEqual(text.count, BlogMeta.seoMaxChars)
        // The date and venue survive the trim: they are the facts worth keeping.
        XCTAssertTrue(text.contains("October 18, 2026"))
        XCTAssertTrue(text.contains("Carnegie Hall"))
        XCTAssertFalse(text.contains("Ver at"), "cut mid-word")
    }

    func testAMissingOrgAndVenueLeaveNoHoleInTheSentence() {
        let text = BlogMeta.seoDescription(
            name: "Open Rehearsal", org: "", venue: "", venueContext: "",
            isoDate: "2026-02-28", shootType: "rehearsal")
        XCTAssertFalse(text.contains(" at ,"))
        XCTAssertFalse(text.contains(", ,"))
        XCTAssertFalse(text.contains("presented by"))
        XCTAssertGreaterThanOrEqual(text.count, BlogMeta.seoMinChars)
    }

    func testADetailsBlockOmitsALineItHasNoValueFor() {
        let text = BlogMeta.detailsBlock(
            name: "Open Rehearsal", org: "", venue: "", venueContext: "",
            isoDate: "2026-02-28", shootType: "rehearsal", eventURL: "")
        // A label with nothing after it reads as a fact that failed to load
        // rather than one the event does not have.
        for line in text.split(separator: "\n") {
            let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, String(line))
        }
        XCTAssertFalse(text.contains("Presented by"))
        XCTAssertFalse(text.contains("Venue"))
        XCTAssertFalse(text.contains("Program"))
    }

    func testAnUnknownShootTypeIsNamedRatherThanPrintedRaw() {
        // A raw enum value reaching the page metadata is worse than a visible
        // gap, because nothing on the post says it is wrong.
        let text = BlogMeta.seoDescription(
            name: "Winter Concert", org: "", venue: "Merkin Hall",
            venueContext: "", isoDate: "2026-11-07",
            shootType: "dress_rehearsal_matinee")
        XCTAssertFalse(text.contains("dress_rehearsal_matinee"))
        XCTAssertTrue(text.contains("Photographs"), text)
    }

    func testAMalformedDateIsNotPrintedRaw() {
        let text = BlogMeta.seoDescription(
            name: "Winter Concert", org: "", venue: "Merkin Hall",
            venueContext: "", isoDate: "not a date", shootType: "performance")
        XCTAssertFalse(text.contains("not a date"))
    }

    // MARK: - Every ShootType is mapped

    func testEveryShootTypeHasProseAndNoneFallsThrough() {
        // Derived from the enum rather than a list here, so a case added later
        // is caught on the day it lands rather than shipping a raw value.
        for type in ShootType.allCases {
            let text = BlogMeta.seoDescription(
                name: "Winter Concert", org: "", venue: "Merkin Hall",
                venueContext: "", isoDate: "2026-11-07",
                shootType: type.pythonValue)
            XCTAssertFalse(text.contains(type.pythonValue),
                           "\(type) prints its raw value")
            XCTAssertGreaterThanOrEqual(text.count, BlogMeta.seoMinChars)
        }
    }

    func testTheEventConvenienceGoesThroughTheSameRules() throws {
        var event = Event(name: "Perpetual Light", org: "DCINY",
                          venue: "Carnegie Hall", date: Date(),
                          shootType: .fullShow)
        event.venueContext = "Stern Auditorium"
        event.eventURL = "https://dciny.org/perpetual-light"
        XCTAssertEqual(BlogMeta.seoDescription(event: event),
                       BlogMeta.seoDescription(name: event.name, org: event.org,
                                               venue: event.venue,
                                               venueContext: event.venueContext,
                                               isoDate: event.isoDate,
                                               shootType: event.shootType.pythonValue))
        XCTAssertEqual(BlogMeta.detailsBlock(event: event),
                       BlogMeta.detailsBlock(name: event.name, org: event.org,
                                             venue: event.venue,
                                             venueContext: event.venueContext,
                                             isoDate: event.isoDate,
                                             shootType: event.shootType.pythonValue,
                                             eventURL: event.eventURL))
    }

    // MARK: - #1106: two twins that nothing was comparing

    func testSwiftRendersEveryStoredDate() throws {
        // `format_date` and `formatDate` are twins found by NAME, not by
        // anybody having declared them. They were covered only through the
        // details block, so a disagreement about one date surfaced as a whole
        // block mismatch and read as a details bug.
        let fixture = try fixture()
        XCTAssertGreaterThanOrEqual(fixture.dates.count, 5,
                                    "a gutted fixture would pass vacuously")

        for date in fixture.dates {
            XCTAssertEqual(BlogMeta.formatDate(date.iso), date.formatted,
                           "\(date.iso) renders differently here than in Python")
        }
    }

    func testSwiftRendersNothingForADateItCannotRead() throws {
        // Where the two halves deliberately DIFFER, and the difference is the
        // point (L542). Python raises, because a malformed date reaching the
        // description would be PUBLISHED as the summary of the post. Swift
        // returns an empty string, because a trap on a rendering path takes the
        // app down.
        //
        // Recorded rather than reconciled: making them agree would either
        // publish a bad date or crash the app.
        for iso in try fixture().unreadable_dates {
            XCTAssertEqual(BlogMeta.formatDate(iso), "",
                           "\(iso) rendered something, so an unreadable date "
                           + "would reach a screen as if it were a real one")
        }
    }

    func testSwiftLabelsEveryStoredShootType() throws {
        // The same map written twice: a dict in Python, a switch here. Nothing
        // compared them, so a shoot type added to one and not the other puts a
        // raw `rehearsal_and_performance` on a published page, or an empty
        // label where a word belongs (L113).
        let labels = try fixture().shoot_types
        XCTAssertGreaterThanOrEqual(labels.count, 4,
                                    "a gutted fixture would pass vacuously")

        for (value, label) in labels {
            XCTAssertEqual(BlogMeta.shootTypeLabel(value), label,
                           "\(value) is labelled differently here than in Python")
        }
    }

    func testTheStoredShootTypesAreEveryOneThisAppKnows() throws {
        // Both directions. A fixture naming a subset would let a type be added
        // to this side alone and go unchecked, which is the drift this exists
        // to catch (L96). Read off `ShootType`, which is what the switch is
        // exhaustive over.
        let stored = Set(try fixture().shoot_types.keys)
        let known = Set(ShootType.allCases.map(\.pythonValue))

        XCTAssertEqual(stored, known,
                       "the shared list and this app's own shoot types are "
                       + "different sets, so one of them is checking a set "
                       + "nobody uses")
    }

}
