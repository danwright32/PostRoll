import XCTest

/// #1160: a way to retry the repairs the app could not finish.
///
/// Two of the five outcomes tell Dan to try again in as many words. `blocked`
/// says the app could not reach the model or could not read the photograph;
/// `not_reached` says the pass ran out of time before this one. Nothing
/// retried, so the panel named a recovery step nothing could perform and left
/// him facing the same panel with no way forward (L109). Repairs are silent,
/// so this panel is the only place the state appears at all.
///
/// The marker each finding is about arrives in the payload as `target`. It is
/// NOT parsed out of `detail`: `detail` embeds the offending text, truncates at
/// 90 characters, and for `stacked_photos` carries no filename at all, so a
/// control reading a filename out of prose matches nothing the day a message
/// is reworded.
final class BlogRepairRetryTests: XCTestCase {

    private func finding(_ code: String, target: String,
                         repair: String) -> QualityFinding {
        QualityFinding(code: code, message: "Alt text must be 15 to 25 words.",
                       detail: "\(target): 9 words", repair: repair,
                       target: target)
    }

    // MARK: - Which states invite a retry

    func testOnlyBlockedAndNotReachedInviteARetry() {
        // The other three must not: `tried` says the app will not get it next
        // time either, `unavailable` says this path has no photograph, and
        // never-attempted is every finding on every post written before the
        // pass existed. Offering a retry on those spends money to reproduce
        // the same answer.
        XCTAssertTrue(RepairState.blocked.invitesRetry)
        XCTAssertTrue(RepairState.notReached.invitesRetry)
        XCTAssertFalse(RepairState.tried.invitesRetry)
        XCTAssertFalse(RepairState.unavailable.invitesRetry)
        XCTAssertFalse(RepairState.never.invitesRetry)
    }

    func testEveryStateThatSaysTryAgainActuallyOffersARetry() {
        // The two halves are written in different places and drifted before:
        // the note said "Worth trying again" and no control did. This ties the
        // wording to the capability, so a state whose note invites a retry and
        // whose control does not appear cannot ship (L109).
        for state in RepairState.allCases {
            let invites = state.note.lowercased().contains("trying again")
            XCTAssertEqual(invites, state.invitesRetry,
                           "\(state.rawValue): its note and its retry "
                         + "capability disagree")
        }
    }

    // MARK: - Which markers a retry would name

    func testTheRetryNamesOnlyTheMarkersInARetryableState() {
        let markers = FindingsDisplay.retryableTargets(findings: [
            finding("alt_text_length", target: "a.jpg", repair: "blocked"),
            finding("alt_text_length", target: "b.jpg", repair: "tried"),
            finding("alt_text_length", target: "c.jpg", repair: "not_reached"),
            finding("alt_text_length", target: "d.jpg", repair: ""),
        ])

        XCTAssertEqual(markers, ["a.jpg", "c.jpg"])
    }

    func testAMarkerNamedByTwoFindingsIsRetriedOnce() {
        // A marker routinely breaks three rules at once, and the retry is a
        // pass over MARKERS. Naming one three times would pay for it three
        // times.
        let markers = FindingsDisplay.retryableTargets(findings: [
            finding("alt_text_length", target: "a.jpg", repair: "blocked"),
            finding("alt_text_missing_venue", target: "a.jpg", repair: "blocked"),
        ])

        XCTAssertEqual(markers, ["a.jpg"])
    }

    func testAFindingWithNoTargetNamesNoMarker() {
        // `stacked_photos` and the prose rules carry no marker. A retry that
        // sent an empty string would ask Python to repair a marker that is not
        // in the post.
        let markers = FindingsDisplay.retryableTargets(findings: [
            QualityFinding(code: "stacked_photos", message: "m", detail: "d",
                           repair: "blocked", target: ""),
        ])

        XCTAssertTrue(markers.isEmpty)
    }

    func testNothingRetryableNamesNoMarkers() {
        // What the control reads to decide whether to appear at all. A control
        // offered when nothing can be retried is the dead control this issue
        // is about, pointing the other way.
        let markers = FindingsDisplay.retryableTargets(findings: [
            finding("alt_text_length", target: "a.jpg", repair: "tried"),
        ])

        XCTAssertTrue(markers.isEmpty)
    }

    // MARK: - The payload

    func testTheTargetArrivesFromPython() throws {
        let json = """
        {"code": "alt_text_length", "message": "m", "detail": "d",
         "repair": "blocked", "target": "a.jpg"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(QualityFinding.self, from: json)

        XCTAssertEqual(decoded.target, "a.jpg")
        XCTAssertEqual(decoded.repairState, .blocked)
    }

    func testAPayloadWithNoTargetStillDecodes() throws {
        // Every post written before this field existed. It decodes with no
        // target and offers no retry, which is correct rather than broken.
        let json = """
        {"code": "alt_text_length", "message": "m", "detail": "d",
         "repair": "blocked"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(QualityFinding.self, from: json)

        XCTAssertEqual(decoded.target, "")
        XCTAssertTrue(FindingsDisplay.retryableTargets(findings: [decoded]).isEmpty)
    }
}
