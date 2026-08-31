import XCTest

/// What counts as an account that can actually be tagged (#926).
///
/// Two functions were named for this one question and asked different things.
/// `PythonBridge.isRealHandle` requires the value to be SHAPED like a username
/// and not be a SENTINEL. `generate_captions._is_real_handle` in Python checked
/// the sentinel half only, so "DPR Dance" passed it, and nothing anywhere
/// asserted the two agreed.
///
/// Checking that pair is not what this file ended up being about. The caption
/// prompt function had had no caller since 2026-05-24, when handles were
/// dropped from the performers block, so it was dead rather than divergent and
/// is gone. The pair that actually spans the bridge is the one below: Python's
/// `week_tags` calls `is_real_handle`, this side's `weekTags` reaches
/// `PythonBridge.isRealHandle` through `TypedCredit.read`, and between them
/// they decide the TAG LIST that gets pasted into Instagram's Tag people field.
///
/// Those two DID disagree, and this side was the wrong one. Python read the
/// sentinel off `bare_username(raw)`; this side read it off the raw value with
/// one leading "@" removed. So `https://instagram.com/unknown/` and
/// `@@unknown` were refused by Python and accepted here, and `TypedCredit` then
/// stripped them down and offered "unknown" to the tag list as an account. That
/// is the defect #917 was filed to stop, arriving by the one route it did not
/// cover.
///
/// Mirrors `tests/test_real_handle.py`. Both read
/// `tests/fixtures/real_handle.json`, which states the sentinel list and every
/// case once, because a rule applied on one side of the bridge only is how all
/// of this happened.
final class RealHandleTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let value: String
            let real: Bool
            let why: String
        }
        let sentinels: [String]
        let cases: [Case]
    }

    private func shared() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self,
            from: try RepoFixture.data("tests/fixtures/real_handle.json"))
    }

    /// Otherwise a run of the shared file says nothing about half the rule, and
    /// a predicate returning a constant would satisfy it (L159).
    func testTheSharedCasesCarryBothAnswers() throws {
        let answers = Set(try shared().cases.map(\.real))
        XCTAssertEqual(answers, [true, false],
                       "the shared cases only ever answer \(answers), so this "
                       + "file cannot tell a predicate that reads the value "
                       + "from one that returns a constant")
    }

    /// The two sides keep their own copies by hand (L41). Held to one list
    /// here, so a word added to either alone is reported by both suites rather
    /// than found later in a caption.
    func testThisSidesSentinelListIsTheSharedOne() throws {
        XCTAssertEqual(PythonBridge.handleSentinels, Set(try shared().sentinels),
                       "PythonBridge.handleSentinels and "
                       + "tests/fixtures/real_handle.json disagree about which "
                       + "words mean 'I looked and there is no Instagram'. "
                       + "Python holds its own copy in "
                       + "caption_blocks.HANDLE_SENTINELS, which "
                       + "tests/test_real_handle.py holds to the same file, so "
                       + "all three move together or none of them do.")
    }

    /// The list and the predicate are checked separately, here and above,
    /// because a list nothing reads is not a rule: an entry could be added to
    /// the fixture and to both sides and still let the word through (L46).
    func testEverySharedSentinelIsRefusedByThePredicate() throws {
        for word in try shared().sentinels {
            XCTAssertFalse(PythonBridge.isRealHandle(word),
                           "\(word) is listed as a sentinel and isRealHandle admits it")
        }
    }

    func testEverySharedCase() throws {
        for shared in try shared().cases {
            XCTAssertEqual(PythonBridge.isRealHandle(shared.value), shared.real,
                           "\(shared.value.isEmpty ? "<empty>" : shared.value): \(shared.why)")
        }
    }
}
