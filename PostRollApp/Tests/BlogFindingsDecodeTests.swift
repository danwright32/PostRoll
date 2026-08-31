import XCTest

/// generate_blog.py returns a `findings` list: the deterministic blog checks
/// from #201 (invented number, alt text too long, a performer grouped by
/// gender). They were reaching stderr and the Python result but never Dan's
/// screen, because BlogOutput only decodes the keys it declares, so the whole
/// enforcement pass was invisible in the app.
final class BlogFindingsDecodeTests: XCTestCase {

    func testFindingsDecodeFromThePythonPayload() throws {
        let json = Data("""
        {"title": "T", "body": "B", "photo_count": 2,
         "findings": [
           {"code": "invented_number",
            "message": "No count in the source data means no number in the post.",
            "detail": "'thirty' does not appear in the program data"}
         ]}
        """.utf8)

        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)

        XCTAssertEqual(blog.findings.count, 1)
        XCTAssertEqual(blog.findings[0].code, "invented_number")
        XCTAssertTrue(blog.findings[0].detail.contains("thirty"))
    }

    func testABlogSavedBeforeFindingsExistedStillDecodes() throws {
        let json = Data(#"{"title": "T", "body": "B"}"#.utf8)
        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)
        XCTAssertTrue(blog.findings.isEmpty)
    }

    func testFindingsSurviveASaveAndReload() throws {
        // They are stored on the event, so a finding must still be on screen
        // after the app is relaunched, not only in the run that produced it.
        var blog = BlogOutput(title: "T", body: "B")
        blog.findings = [QualityFinding(code: "alt_text_length",
                                     message: "Alt text must be 15 to 25 words.",
                                     detail: "a.jpg: 34 words.")]

        let round = try JSONDecoder().decode(
            BlogOutput.self, from: try JSONEncoder().encode(blog))

        XCTAssertEqual(round.findings.first?.code, "alt_text_length")
    }

    // MARK: - The body the checks ran on (#974)

    func testAGeneratedBlogCarriesTheBodyItsFindingsWereMeasuredAgainst() throws {
        // The defect this closes. `findings_body` was declared here and emitted
        // by nothing, so every generated post decoded an empty pin and the
        // panel could never report itself out of date. Measured on the live
        // store on 2026-08-31: 21 blogs, 2 carrying findings, none pinned.
        let json = Data("""
        {"title": "T", "body": "the draft as generated", "photo_count": 2,
         "findings": [
           {"code": "invented_number", "message": "m", "detail": "d"}
         ],
         "findings_body": "the draft as generated"}
        """.utf8)

        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)

        XCTAssertEqual(blog.findingsBody, "the draft as generated")
        XCTAssertFalse(blog.findingsAreStale, "nothing has been edited yet")
    }

    func testEditingAGeneratedDraftMakesItsFindingsSayTheyAreOutOfDate() throws {
        // The half a decode assertion misses: the pin has to reach the reader
        // that uses it. Built is not wired (L3).
        let json = Data("""
        {"title": "T", "body": "the draft as generated", "photo_count": 2,
         "findings": [
           {"code": "invented_number", "message": "m", "detail": "d"}
         ],
         "findings_body": "the draft as generated"}
        """.utf8)

        var blog = try JSONDecoder().decode(BlogOutput.self, from: json)
        blog.body = "Dan rewrote the middle of it"

        XCTAssertTrue(blog.findingsAreStale)
        XCTAssertEqual(blog.findingsSummary, "1 check against the original draft")
    }

    func testABlogSavedBeforeThePinExistedIsStillNotTreatedAsStale() throws {
        // Every event in the store predates this key. They genuinely have no
        // record of what was measured, and greying out their findings would be
        // asserting an edit that nothing observed.
        let json = Data("""
        {"title": "T", "body": "an older draft", "photo_count": 2,
         "findings": [
           {"code": "invented_number", "message": "m", "detail": "d"}
         ]}
        """.utf8)

        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)

        XCTAssertEqual(blog.findingsBody, "")
        XCTAssertFalse(blog.findingsAreStale)
    }
}
