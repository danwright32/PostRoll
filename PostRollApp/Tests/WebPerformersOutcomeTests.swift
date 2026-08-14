import XCTest

/// #449: a fetch that failed is not a website with nobody on it.
///
/// The DCINY performer fetch sat behind `try?`. A network failure, a dead
/// script or a changed page produced the same nothing as a page that genuinely
/// lists no performers, both fell through to the program's list, and the run
/// reported clean. The program lists every individual member where the site
/// lists the group and its conductor, so the difference reaches Dan as a cast
/// list two or three times too long with nothing saying why (L11).
final class WebPerformersOutcomeTests: XCTestCase {

    private func performer(_ name: String) -> Performer {
        Performer(name: name, role: "Conductor")
    }

    func testPerformersFromTheSiteAreUsed() {
        let found = [performer("Ola Gjeilo")]

        XCTAssertEqual(WebPerformersOutcome.decide(fetched: found, failure: nil),
                       .use(found))
    }

    func testAPageThatListsNobodyKeepsTheProgramList() {
        guard case .keepProgramList(let reason) = WebPerformersOutcome.decide(
            fetched: [], failure: nil) else {
            return XCTFail("an empty page did not fall back to the program")
        }
        XCTAssertFalse(reason.isEmpty, "no reason was recorded")
    }

    /// The whole issue. A failed fetch must not take the same branch, silently,
    /// as a page with nothing on it.
    func testAFailedFetchRecordsTheReasonItGives() {
        guard case .keepProgramList(let reason) = WebPerformersOutcome.decide(
            fetched: nil, failure: "the request timed out") else {
            return XCTFail("a failed fetch was not reported")
        }
        XCTAssertEqual(reason, "the request timed out")
    }

    func testTheTwoCausesDoNotSayTheSameThing() {
        guard case .keepProgramList(let empty) = WebPerformersOutcome.decide(
                fetched: [], failure: nil),
              case .keepProgramList(let failed) = WebPerformersOutcome.decide(
                fetched: nil, failure: "the request timed out")
        else { return XCTFail("expected both to keep the program list") }

        XCTAssertNotEqual(empty, failed,
                          "a failed fetch and an empty page give the same reason, so "
                          + "nothing on screen can tell them apart")
    }

    /// Performers that arrived before the error are not the site's list.
    func testAFailureWinsOverAPartialAnswer() {
        guard case .keepProgramList = WebPerformersOutcome.decide(
            fetched: [performer("half a name")], failure: "the request timed out") else {
            return XCTFail("a partial answer masked the failure that produced it")
        }
    }

    /// A blank reason is not a reason, and must not be treated as one.
    func testAnEmptyFailureStringIsNotAFailure() {
        let found = [performer("Ola Gjeilo")]

        XCTAssertEqual(WebPerformersOutcome.decide(fetched: found, failure: "   "),
                       .use(found))
    }
}
