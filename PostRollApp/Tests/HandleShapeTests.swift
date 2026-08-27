import XCTest

/// What may be stored in a handle field, and what may not (#899).
///
/// On Battery Dance Festival, Thursday, a company's row carried its own display
/// name in the handle field, `'DPR Dance' -> handle: 'DPR Dance'`, and nothing
/// anywhere checked that a handle was SHAPED like a handle. `isRealHandle` is a
/// blacklist of seven sentinel words and passed it, `CaptionCreditInputs`
/// emitted `@DPR Dance` into `tag_handles` as a handle to mention, and the model
/// wrote it into a caption bound for Instagram, where `@DPR` resolves to
/// whoever owns that account.
///
/// Mirrors `tests/test_handle_shape.py`. Both read
/// `tests/fixtures/handle_shape.json`, which states every case once, because a
/// rule applied on one side of the bridge only is how this happened.
final class HandleShapeTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let value: String
            let shaped: Bool
            let why: String
        }
        let cases: [Case]
    }

    private func loadCases() throws -> [Fixture.Case] {
        try JSONDecoder().decode(
            Fixture.self,
            from: try RepoFixture.data("tests/fixtures/handle_shape.json")).cases
    }

    /// Otherwise a run of the shared file says nothing about half the rule, and
    /// a predicate returning a constant would satisfy it (L159).
    func testTheSharedCasesCarryBothAnswers() throws {
        let answers = Set(try loadCases().map(\.shaped))
        XCTAssertEqual(answers, [true, false],
                       "the shared cases only ever answer \(answers), so this "
                       + "file cannot tell a predicate that reads the value "
                       + "from one that returns a constant")
    }

    func testEverySharedCase() throws {
        for shared in try loadCases() {
            XCTAssertEqual(CaptionBlocks.isHandleShaped(shared.value), shared.shaped,
                           "\(shared.value.isEmpty ? "<empty>" : shared.value): \(shared.why)")
        }
    }
}
