import XCTest

/// #401: one classifier, and the property that was never true while there were
/// two of them.
final class RunFailureKindTests: XCTestCase {

    // MARK: - The property that would have caught the drift

    /// Every needle either producer used to match, classified once.
    ///
    /// This is the check that was missing: while `PythonBridgeError.humanise` and
    /// `GenerationFailureText` each held their own copy of this matching, nothing
    /// compared them, and they had already drifted on `401`, on `overloaded` and
    /// on how long to wait for a rate limit.
    private static let needles: [(text: String, expected: RunFailureKind)] = [
        ("RuntimeError: ffmpeg not found on PATH", .ffmpegMissing),
        ("JAMENDO_CLIENT_ID is not set", .audioServiceUnreachable),
        ("anthropic api error: request_too_large", .requestTooLarge),
        ("HTTP 413 payload too large", .requestTooLarge),
        ("request exceeds the maximum size", .requestTooLarge),
        ("anthropic api error: rate_limit_error", .rateLimited),
        ("HTTP 429 too many requests", .rateLimited),
        ("hit the rate limit", .rateLimited),
        ("anthropic api error: overloaded_error", .overloaded),
        ("HTTP 529", .overloaded),
        ("invalid_api_key", .authFailed),
        ("HTTP 401 unauthorized", .authFailed),
        ("authentication failed", .authFailed),
        ("no api key configured", .authFailed),
        ("anthropic api error: something new", .aiServiceError),
        ("no performers found in ocr data", .performersMissing),
        ("pieces is empty", .piecesMissing),
        ("FileNotFoundError: /photos/a.jpg", .fileMissing),
        ("no such file or directory", .fileMissing),
        ("story fallback failed", .storyFallbackFailed),
        ("JSONDecodeError: expecting value", .outputUnreadable),
        ("KeyError 'zzz' in collage_planner.py", .unknown),
    ]

    func testEveryKnownFailureTextClassifiesToExactlyOneKind() {
        for (text, expected) in Self.needles {
            XCTAssertEqual(RunFailureKind.of(text), expected,
                           "\"\(text)\" was read as \(RunFailureKind.of(text))")
        }
    }

    /// Both message producers see the same kind for the same text.
    ///
    /// The whole point of #401: a run that died and a day that died must not be
    /// told apart by anything except the wording.
    func testTheWholeRunPathAndThePerDayPathAgree() {
        for (text, expected) in Self.needles {
            XCTAssertEqual(RunFailureKind.of(text, day: "sunday"), expected,
                           "\"\(text)\" classifies differently when it comes from a day")
        }
    }

    /// One wait per kind, so no two messages can print different ones.
    func testTheWaitIsDecidedByTheKindRatherThanTheMessage() {
        XCTAssertEqual(RunFailureKind.rateLimited.waitAdvice, "about 30 seconds")
        XCTAssertEqual(RunFailureKind.overloaded.waitAdvice, "a minute")
        XCTAssertNil(RunFailureKind.ffmpegMissing.waitAdvice,
                     "waiting does not install ffmpeg, so no wait may be suggested")
        XCTAssertNil(RunFailureKind.fileMissing.waitAdvice)
    }

    // MARK: - The digit hazard PythonBridgeLog documented

    /// `PythonBridgeLog`'s comment names this exactly: a UUID containing 413
    /// hijacking the classification and misreporting an unrelated failure.
    func testAStatusCodeInsideAnIdentifierIsNotAStatusCode() {
        let cases = [
            "run 8a413f2c-1d9e failed",
            "traceback in file_1413.py",
            "photo DSC_4295.jpg could not be read",
            "seed 5290",
        ]
        for text in cases {
            let kind = RunFailureKind.of(text)
            XCTAssertNotEqual(kind, .requestTooLarge, text)
            XCTAssertNotEqual(kind, .rateLimited, text)
            XCTAssertNotEqual(kind, .overloaded, text)
            XCTAssertNotEqual(kind, .authFailed, text)
        }
    }

    func testABareStatusCodeWithPunctuationAroundItStillCounts() {
        XCTAssertEqual(RunFailureKind.of("error(429): slow down"), .rateLimited)
        XCTAssertEqual(RunFailureKind.of("status=413"), .requestTooLarge)
        XCTAssertEqual(RunFailureKind.of("[401]"), .authFailed)
    }

    // MARK: - Ordering, which is where the two copies disagreed

    /// A payload that is too large is also an anthropic api error. Reading it as
    /// the generic one tells Dan to retry something that will fail identically.
    func testTheSpecificServiceFailureBeatsTheGenericOne() {
        XCTAssertEqual(
            RunFailureKind.of("anthropic api error: request_too_large: 40 images"),
            .requestTooLarge)
        XCTAssertEqual(
            RunFailureKind.of("anthropic api error: rate_limit_error (429)"), .rateLimited)
    }

    /// An absent ffmpeg often carries a stack trace through the AI client
    /// library. Reading that as a service problem sends Dan to check his API key
    /// over a missing brew package.
    func testLocalToolingBeatsAStackTraceThatMentionsTheService() {
        let text = "Traceback:\n  File \"/x/anthropic/client.py\"\n"
                 + "FileNotFoundError: [Errno 2] No such file or directory: 'ffmpeg'"
        XCTAssertEqual(RunFailureKind.of(text), .ffmpegMissing)
    }

    /// ffmpeg being NAMED is not ffmpeg being MISSING (#403).
    ///
    /// Every ffmpeg wrapper in postroll/media prefixes its message with the word,
    /// so the word carries no information about whether the binary is installed.
    /// The real cause is further down its own stderr, and here it is a photo that
    /// is not on disk, which Dan can fix and which the install advice hid.
    func testFFmpegRanAndFailedIsNotFFmpegMissing() {
        let text = "ffmpeg failed: [in#0 @ 0x9f2c] Error opening input: "
                 + "No such file or directory\n"
                 + "Error opening input file /photos/thursday/DSC_4417.jpg.\n"
        let kind = RunFailureKind.of(text)

        XCTAssertEqual(kind, .fileMissing, "the missing photo is the cause, not the tool")
        XCTAssertTrue(kind.isFixableFromTheApp,
                      "and re-assigning that photo is something Dan can do")
    }

    /// A prompt past the context window arrives as an ordinary 400, so it has to
    /// be recognised by its words. Waiting does not shorten a prompt.
    func testAPromptPastTheWindowIsReadAsTooMuchInput() {
        let text = "Anthropic API error: Error code: 400 - {'type': 'error', 'error': "
                 + "{'type': 'invalid_request_error', 'message': 'prompt is too long: "
                 + "1048576 tokens > 1000000 maximum'}}"
        let kind = RunFailureKind.of(text)

        XCTAssertEqual(kind, .requestTooLarge)
        XCTAssertTrue(kind.isFixableFromTheApp, "sending less is the only thing that fixes it")
        XCTAssertNil(kind.waitAdvice, "waiting does not shorten a prompt")
    }

    /// The drift this issue exists to settle, and the direction it settled in.
    ///
    /// One old copy matched a bare "anthropic", which any traceback passing
    /// through the client library satisfies, so a ValueError in Dan's own code
    /// was reported as a connection problem and told him to check his API key.
    /// A failure is only the service's when the service said so.
    func testTheServiceNameInAFilePathIsNotAServiceFailure() {
        let text = "Traceback (most recent call last):\n"
                 + "  File \"/x/anthropic/client.py\", line 9\n"
                 + "ValueError: bad photo list"
        XCTAssertEqual(RunFailureKind.of(text), .unknown,
                       "nothing here was said by the service, so nothing may be claimed")
        XCTAssertTrue(RunFailureKind.of(text).isFixableFromTheApp,
                      "and the route back to inputs stays open, because this could be inputs")
    }

    /// `parse` and `decode` appear inside other failures' stack traces, so they
    /// are checked last.
    func testAParseWordInsideAnotherFailureDoesNotWin() {
        XCTAssertEqual(
            RunFailureKind.of("no such file: /photos/parse_test.json"), .fileMissing)
    }

    // MARK: - Per-day kinds

    func testBeforeAfterInputsAreOnlyReadOnTheDaysThatHaveThem() {
        XCTAssertEqual(RunFailureKind.of("raw photo missing", day: "tuesday"),
                       .beforeAfterInputsMissing(day: "tuesday"))
        XCTAssertEqual(RunFailureKind.of("edited photo missing", day: "friday"),
                       .beforeAfterInputsMissing(day: "friday"))
        XCTAssertEqual(RunFailureKind.of("raw photo missing", day: "sunday"), .unknown,
                       "Sunday has no before/after pair, so this is not that failure")
    }

    func testAReelWithNoPhotosIsItsOwnKind() {
        XCTAssertEqual(RunFailureKind.of("photo list is empty", day: "thursday"),
                       .reelPhotosMissing)
    }

    /// Without a day there is no per-day kind to reach, and the text falls
    /// through to something more general rather than guessing a day.
    func testAWholeRunFailureCannotReachAPerDayKind() {
        XCTAssertEqual(RunFailureKind.of("raw photo missing"), .unknown)
    }

    // MARK: - Fixability

    /// What this controls: whether the route back to the photo screen is offered.
    /// A wrong answer sends Dan to change inputs that were never the problem.
    func testNothingDanCanChangeInTheAppFixesAServiceOrToolingFailure() {
        for kind in [RunFailureKind.ffmpegMissing, .audioServiceUnreachable, .rateLimited,
                     .overloaded, .authFailed, .aiServiceError] {
            XCTAssertFalse(kind.isFixableFromTheApp, "\(kind)")
        }
    }

    func testEveryInputFailureIsFixableFromTheApp() {
        for kind in [RunFailureKind.fileMissing, .performersMissing, .piecesMissing,
                     .reelPhotosMissing, .storyFallbackFailed, .requestTooLarge,
                     .beforeAfterInputsMissing(day: "tuesday")] {
            XCTAssertTrue(kind.isFixableFromTheApp, "\(kind)")
        }
    }

    /// An unrecognised failure keeps the route open, because the raw error is
    /// always shown beside it and an extra route hides nothing.
    func testAnUnknownFailureKeepsTheRouteOpenWithoutClaimingToKnowWhy() {
        XCTAssertTrue(RunFailureKind.unknown.isFixableFromTheApp)
        XCTAssertNil(RunFailureKind.unknown.waitAdvice,
                     "no advice may be given about a failure we did not recognise")
    }
}
