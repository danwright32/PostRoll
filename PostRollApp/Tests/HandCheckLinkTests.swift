import XCTest

/// The link the hand check fires is one the app will actually open (#866).
///
/// Step 4 of `docs/HAND-CHECK.md` fires a `postroll://` link and then asks
/// whether pressing Return commits the form it raised. The whole step rests on
/// the link being GOOD: a refused link raises no form at all, so Return has
/// nothing to commit, and the step's expected result, that nothing happens, is
/// exactly what a broken link produces too. The check would then pass while
/// measuring nothing, and it would pass hardest when the link was most wrong
/// (L159).
///
/// That is not hypothetical. The first version of the script wrote the date as
/// `2026-09-01`, which `DeepLink.day` refuses: it takes eight digits and
/// nothing else. Reading the parser is what caught it, and reading it is not
/// something the next person to touch the script will do.
///
/// So the link is put through the app's own parser rather than through a second
/// description of what a good link looks like. A rule about URLs written beside
/// the one that actually decides is a second definition, and it drifts in
/// whichever direction flatters the test (L107).
final class HandCheckLinkTests: XCTestCase {

    private var scriptSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hand-check.sh")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The one `url=` assignment in the script, and a failure when there is not
    /// exactly one. Zero means this test is reading nothing and would pass on
    /// any script at all (L98); two means it cannot say which link the
    /// checklist actually fires.
    private func linkFromScript() throws -> URL {
        let assignments = try scriptSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("url=\"") }

        XCTAssertEqual(assignments.count, 1,
                       "hand-check.sh holds \(assignments.count) link "
                       + "assignments, so which one step 4 fires is undecided")
        let line = try XCTUnwrap(assignments.first)
        let text = line.dropFirst("url=\"".count).dropLast()
        return try XCTUnwrap(URL(string: String(text)),
                             "the script's link is not a URL at all: \(text)")
    }

    func testTheLinkTheChecklistFiresIsOneTheAppAccepts() throws {
        let url = try linkFromScript()

        switch DeepLink.draft(from: url) {
        case .success:
            break
        case .failure(let refusal):
            XCTFail("step 4 of the hand check fires a link PostRoll refuses, so "
                    + "no form opens and the step's expected result is what a "
                    + "broken link produces anyway. PostRoll would say: "
                    + refusal.message)
        }
    }

    func testTheLinkCarriesTheValuesTheChecklistTellsYouToLookFor() throws {
        // The step says the form opens "already filled in with Hand check, Test
        // Company, Test Hall, Main Stage and 1 September 2026". Those words are
        // the only way to tell a form the link filled from an empty one, so they
        // have to be what the link actually carries.
        let url = try linkFromScript()
        guard case .success(let draft) = DeepLink.draft(from: url) else {
            return XCTFail("the link is refused, which the test above says more about")
        }

        XCTAssertEqual(draft.name, "Hand check")
        XCTAssertEqual(draft.org, "Test Company")
        XCTAssertEqual(draft.venue, "Test Hall")
        XCTAssertEqual(draft.venueContext, "Main Stage")

        let parts = Calendar.current.dateComponents([.year, .month, .day], from: draft.date)
        XCTAssertEqual(parts.year, 2026, "the checklist says 2026")
        XCTAssertEqual(parts.month, 9, "the checklist says September")
        XCTAssertEqual(parts.day, 1, "the checklist says the 1st")
    }

    func testTheSameLinkFiredTwiceNamesTheSameBooking() throws {
        // A fixed booking id, not a fresh one per run. Firing the link twice has
        // to be seen to say the event already exists, which is how the refusal
        // path gets looked at at all; a generated id would quietly make a second
        // event and the step would read as working.
        let url = try linkFromScript()
        guard case .success(let first) = DeepLink.draft(from: url),
              case .success(let second) = DeepLink.draft(from: url) else {
            return XCTFail("the link is refused, which the test above says more about")
        }

        XCTAssertEqual(first.bookingID, second.bookingID,
                       "the checklist's link carries a different booking id "
                       + "each time it is read, so firing it twice makes two "
                       + "events rather than reporting the first one")
    }
}
