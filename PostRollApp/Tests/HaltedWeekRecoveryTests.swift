import XCTest

/// #262: the halted-week reader is actually reachable.
///
/// #257 decoded `stopped_reason` and built the halt screen, and it could never
/// fire. A halt raises out of `generate_week`, so Python exits non-zero, so
/// `runProcess` throws, so `runWeekGeneration` returned before it ever opened
/// the results file. The reason, and every day that had finished, went to the
/// temp directory's cleanup along with it.
///
/// That is the same defect #257 was filed for, one layer down: built is not
/// wired, and wired is not proven (L3). What proves it here is that the
/// decision to read a failed run's partial output is a pure function with the
/// failing shapes enumerated, rather than a line buried in a subprocess call
/// nothing can reach.
final class HaltedWeekRecoveryTests: XCTestCase {

    private func payload(_ json: String) -> Data { Data(json.utf8) }

    // ── reading a failed run's leftovers ──────────────────────────────────────

    func testAFailedRunCarryingAStopReasonIsReadAsAHalt() throws {
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("""
            {"sunday": {"caption": "Sunday copy"},
             "errors": {}, "warnings": {},
             "complete": false,
             "stopped_reason": "Claude usage limit reached, resets at 3pm."}
            """),
            underlying: PythonBridgeError.scriptFailed(exitCode: 1, stderr: "FatalGenerationError"))

        guard case .halted(let week) = outcome else {
            return XCTFail("a capped week read as an ordinary crash, so the day "
                           + "that finished looks lost and the only offer is to "
                           + "re-run the whole week")
        }
        XCTAssertEqual(week.stoppedReason, "Claude usage limit reached, resets at 3pm.")
        XCTAssertEqual(week.sunday?.caption, "Sunday copy",
                       "the days that finished are real and must survive the halt")
    }

    func testTheHaltScreenCanBeBuiltFromWhatWasRecovered() throws {
        // The end of the wire: a recovered payload has to reach the screen #257
        // built, or this fix stops one step short of the thing that was broken.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("""
            {"sunday": {"caption": "a"}, "monday": {"caption": "b"},
             "errors": {}, "warnings": {}, "complete": false,
             "stopped_reason": "Claude usage limit reached"}
            """),
            underlying: PythonBridgeError.outputMissing)
        guard case .halted(let week) = outcome else { return XCTFail("not read as a halt") }

        let halted = try XCTUnwrap(HaltedWeek.from(week))
        XCTAssertEqual(halted.reason, "Claude usage limit reached")
        XCTAssertEqual(halted.finishedDays, [.sunday, .monday])
    }

    func testAnOrdinaryCrashIsStillAnOrdinaryFailure() {
        // The halt screen offers to spend money. Showing it for a crash that was
        // never a cap invites Dan to pay to retry something a retry would fix.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload(#"{"errors": {"sunday": "boom"}, "warnings": {}, "complete": false}"#),
            underlying: PythonBridgeError.scriptFailed(exitCode: 1, stderr: "boom"))
        guard case .failed = outcome else {
            return XCTFail("a crash with no stop reason must not offer the paid re-run")
        }
    }

    func testABlankStopReasonIsNotAHalt() {
        // `stopped_reason` is written on every save, so treating "present" as
        // "halted" would put the paid-re-run screen in front of every failure.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload(#"{"errors": {}, "warnings": {}, "stopped_reason": "   "}"#),
            underlying: PythonBridgeError.outputMissing)
        guard case .failed = outcome else { return XCTFail("a blank reason is not a halt") }
    }

    func testNoOutputFileAtAllIsAnOrdinaryFailure() {
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: nil,
            underlying: PythonBridgeError.scriptFailed(exitCode: 1, stderr: "died early"))
        guard case .failed = outcome else { return XCTFail("nothing on disk is not a halt") }
    }

    func testUndecodableLeftoversAreAnOrdinaryFailureNotASilentSuccess() {
        // A truncated or garbage file must not become a blank week that reads as
        // a finished one. The original error is what Dan needs to see.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("{ this is not json"),
            underlying: PythonBridgeError.scriptFailed(exitCode: 1, stderr: "died"))
        guard case .failed(let error, _) = outcome else {
            return XCTFail("unreadable leftovers must not be presented as a week")
        }
        XCTAssertTrue(error is PythonBridgeError)
    }

    func testAHaltKeepsTheReasonRatherThanTheProcessError() throws {
        // The process error is a traceback. The reason is the sentence written
        // for Dan. A message may only claim what its check measured (L11).
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("""
            {"errors": {}, "warnings": {}, "complete": false,
             "stopped_reason": "Claude usage limit reached, resets at 3pm. Everything generated so far is saved."}
            """),
            underlying: PythonBridgeError.scriptFailed(
                exitCode: 1, stderr: "Traceback (most recent call last): FatalGenerationError"))
        guard case .halted(let week) = outcome else { return XCTFail("not a halt") }
        XCTAssertFalse(week.stoppedReason?.contains("Traceback") ?? true)
    }

    // ── a run the watchdog killed ─────────────────────────────────────────────

    func testARunKilledMidWayIsNotPresentedAsAFinishedWeek() throws {
        // The 1800s watchdog SIGTERMs the subprocess. No exception is raised, so
        // nothing writes a stop reason, and the file on disk says only
        // `complete: false`. Before #262 nothing read that key, so a week that
        // was cut off mid-run showed as done with days silently missing.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("""
            {"sunday": {"caption": "a"}, "errors": {}, "warnings": {}, "complete": false}
            """),
            underlying: PythonBridgeError.timedOut(seconds: 1800))
        guard case .failed = outcome else {
            return XCTFail("a killed run has no stop reason and is not a halt: there "
                           + "is no cap, so there is nothing to offer to pay for")
        }
    }

    func testAKilledRunsFinishedDaysAreSalvagedRatherThanThrownAway() throws {
        // `generate_week` persists after every day for exactly this case (#206),
        // and nothing read the file on the failure path, so up to half an hour
        // of paid captions went to the temp directory's cleanup.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("""
            {"sunday": {"caption": "Sunday copy"}, "monday": {"caption": "Monday copy"},
             "errors": {}, "warnings": {}, "complete": false}
            """),
            underlying: PythonBridgeError.timedOut(seconds: 1800))

        guard case .failed(_, let salvaged) = outcome else { return XCTFail("expected a failure") }
        let week = try XCTUnwrap(salvaged, "two finished captions were discarded")
        XCTAssertEqual(week.sunday?.caption, "Sunday copy")
        XCTAssertEqual(week.monday?.caption, "Monday copy")
        XCTAssertFalse(week.complete)
    }

    func testARunThatProducedNothingHasNothingToSalvage() {
        // Offering an empty week here would let the merge overwrite a good saved
        // week with blanks, which is the opposite of the point.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload(#"{"errors": {"sunday": "boom"}, "warnings": {}, "complete": false}"#),
            underlying: PythonBridgeError.timedOut(seconds: 1800))
        guard case .failed(_, let salvaged) = outcome else { return XCTFail("expected a failure") }
        XCTAssertNil(salvaged)
    }

    func testSalvagedDaysAreStampedSoEditTrackingWorks() throws {
        // Without stampOriginals the salvaged captions have no "as generated"
        // copy, so the review screen reports every one of them as edited.
        let outcome = PythonBridge.weekOutcome(
            forFailedRun: payload("""
            {"sunday": {"caption": "Sunday copy"}, "errors": {}, "warnings": {}, "complete": false}
            """),
            underlying: PythonBridgeError.timedOut(seconds: 1800))
        guard case .failed(_, let salvaged) = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(salvaged?.sunday?.generatedCaption, "Sunday copy")
        XCTAssertFalse(salvaged?.sunday?.wasEdited ?? true)
    }

    func testAFinishedWeekKnowsItFinished() throws {
        let json = #"{"errors": {}, "warnings": {}, "complete": true}"#
        let week = try JSONDecoder().decode(WeekGenerationResult.self, from: payload(json))
        XCTAssertTrue(week.complete)
    }

    func testAWeekSavedBeforeCompleteExistedIsNotCalledUnfinished() throws {
        // Every persisted field must tolerate its own absence, and the default
        // here has to be `true`: an old saved week really did finish, and
        // defaulting to false would relabel Dan's whole history as cut off.
        let week = try JSONDecoder().decode(
            WeekGenerationResult.self, from: payload(#"{"errors": {}, "warnings": {}}"#))
        XCTAssertTrue(week.complete)
    }

    func testAnUnfinishedWeekIsVisibleAsSuch() throws {
        let week = try JSONDecoder().decode(
            WeekGenerationResult.self,
            from: payload(#"{"sunday": {"caption": "a"}, "errors": {}, "warnings": {}, "complete": false}"#))
        XCTAssertFalse(week.complete)
    }

    // ── the unrecognised failures the cap work is waiting on ──────────────────

    func testUnrecognisedFailuresSurviveIntoTheWeek() throws {
        // #217 wrote these "so the app can show it, not only stderr", and
        // nothing decoded them. #258 cannot be worked on until a real cap's
        // wording is captured, and Dan is the one who sees the run.
        let week = try JSONDecoder().decode(WeekGenerationResult.self, from: payload("""
        {"errors": {}, "warnings": {}, "complete": true,
         "unrecognised_failures": ["upstream connect error", "something new"]}
        """))
        XCTAssertEqual(week.unrecognisedFailures, ["upstream connect error", "something new"])
        XCTAssertTrue(week.hasUnrecognisedFailures)
    }

    func testAnOrdinaryWeekReportsNoUnrecognisedFailures() throws {
        let week = try JSONDecoder().decode(
            WeekGenerationResult.self, from: payload(#"{"errors": {}, "warnings": {}}"#))
        XCTAssertTrue(week.unrecognisedFailures.isEmpty)
        XCTAssertFalse(week.hasUnrecognisedFailures,
                       "an empty list must not light up a notice on every ordinary run")
    }
}
