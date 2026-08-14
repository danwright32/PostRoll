import XCTest

/// #396: the failure copy the generation done screen shows, which decided
/// whether Dan gets a route back to the photo screen and had no test at all
/// while it lived inside the view.
final class GenerationFailureTextTests: XCTestCase {

    func testTheRawErrorIsAlwaysCarriedAlongsideTheHint() {
        let (text, _) = GenerationFailureText.humanize(
            day: "thursday", raw: "RuntimeError: ffmpeg not found on PATH")

        XCTAssertTrue(text.contains("brew install ffmpeg"), "the hint has to be there")
        XCTAssertTrue(text.contains("RuntimeError: ffmpeg not found on PATH"),
                      "so does the raw error, because the hint is a guess and the raw "
                      + "text is the part Dan can act on")
    }

    func testAnUnrecognisedErrorIsShownVerbatimRatherThanExplainedAway() {
        let raw = "Traceback: KeyError 'zzz' in collage_planner.py line 42"
        let (text, fixable) = GenerationFailureText.humanize(day: "sunday", raw: raw)

        XCTAssertEqual(text, raw, "no invented explanation for something we do not recognise")
        XCTAssertTrue(fixable, "an unknown cause keeps the route back to inputs open")
    }

    // MARK: - Which failures Dan can fix himself

    /// The consequence of `fixable`: a wrong answer here sends him to change
    /// inputs that were never the problem, or hides the route when they were.
    func testSystemAndServiceFailuresAreNotFixableFromTheGUI() {
        let notFixable = [
            "ffmpeg: command not found",
            "jamendo_client_id is not set",
            "anthropic api error: rate_limit_error",
            "HTTP 429 too many requests",
            // The service's own spelling. This row read "invalid_api_key" until
            // #522, which is an OpenAI code and could never have arrived here.
            "authentication_error",
            "HTTP 401 unauthorized",
            "overloaded_error",
        ]
        for raw in notFixable {
            let (_, fixable) = GenerationFailureText.humanize(day: "sunday", raw: raw)
            XCTAssertFalse(fixable, "\"\(raw)\" is not fixed by changing photos")
        }
    }

    func testMissingInputsAreFixableFromTheGUI() {
        let fixable: [(String, String)] = [
            ("tuesday", "raw photo missing"),
            ("friday", "edited photo missing"),
            ("thursday", "photo list is empty"),
            ("sunday", "FileNotFoundError: /photos/a.jpg"),
            ("monday", "no such file or directory"),
            ("wednesday", "story fallback failed"),
            ("sunday", "request_too_large"),
        ]
        for (day, raw) in fixable {
            let (_, isFixable) = GenerationFailureText.humanize(day: day, raw: raw)
            XCTAssertTrue(isFixable, "\"\(raw)\" on \(day) is fixed by changing inputs")
        }
    }

    /// An "anthropic" mention in a stack trace must not be read as an auth
    /// failure, which is the misclassification the specific matches exist for.
    func testAStackTraceMentioningAnthropicIsNotReadAsAnAuthFailure() {
        let raw = "Traceback (most recent call last):\n  File \"/x/anthropic/client.py\", "
                + "line 9\nValueError: bad photo list"
        let (text, fixable) = GenerationFailureText.humanize(day: "sunday", raw: raw)

        XCTAssertFalse(text.contains("API key"), "nothing here says the key is wrong")
        XCTAssertTrue(fixable)
    }

    // MARK: - Labels

    func testTheTwoKeysThatAreNotDaysGetTheirOwnNames() {
        XCTAssertEqual(GenerationFailureText.dayLabel("blog"), "Blog post")
        XCTAssertEqual(GenerationFailureText.dayLabel(PreviewMergePolicy.graphicsRunKey),
                       "Visual assets")
        XCTAssertEqual(GenerationFailureText.dayLabel("thursday"), "Thursday")
    }

    func testTheRetrySentenceReadsAsEnglishAtEveryLength() {
        XCTAssertEqual(GenerationFailureText.summarySentence([]), "")
        XCTAssertEqual(GenerationFailureText.summarySentence(["Sunday"]), "Sunday")
        XCTAssertEqual(GenerationFailureText.summarySentence(["Sunday", "Blog post"]),
                       "Sunday and Blog post")
        XCTAssertEqual(
            GenerationFailureText.summarySentence(["Sunday", "Thursday", "Blog post"]),
            "Sunday, Thursday, and Blog post")
    }
}
