import XCTest

/// #402: a refusal that gets computed has to reach the screen.
///
/// The defect twice over. `StageNavigation.blockedReason` wrote a sentence naming
/// the missing work and handed it only to `.help()`, so pressing a greyed step in
/// the stage strip did nothing and explained nothing, on a strip drawn on every
/// screen. `NewEventSheet` did not even compute one: two required fields, a
/// button at 40% opacity, and no way to learn which field was empty.
///
/// A hover tooltip does not count as saying it. `.help()` is invisible until the
/// mouse rests on the control, and nobody rests a mouse on something that looks
/// dead (L49, L109).
///
/// The strongest check on this is not here: `BannerLegibilityTests` renders both
/// refusals and measures ink on the page, which is the only way to know they are
/// legible rather than merely present. What these add is the two things a render
/// cannot see: that the producers are still wired up, and that the specific
/// tooltip-only shape has not come back.
final class VisibleRefusalGuardTests: XCTestCase {

    /// The functions in this app whose whole purpose is to explain a refusal.
    ///
    /// Named rather than derived, and checked in both directions, because a stale
    /// entry silently exempts whatever drifts into its place (L96).
    private static let refusalProducers = [
        "StageNavigation.blockedReason",
        "NewEventValidation.refusal",
        "OCRReviewReadiness.confirmHelp",
        "ExportReadiness.blockedReason",
    ]

    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// Source with comment lines stripped.
    ///
    /// A guard that matches on raw source can be satisfied by prose ABOUT the
    /// thing, including a comment explaining that the thing was removed, which is
    /// indistinguishable from working (L103). It matters here specifically: the
    /// tooltip-only site carried a comment claiming it said which work was
    /// missing, and that comment was true of the intent and false of the screen.
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") }
            .joined(separator: "\n")
    }

    private func code(in subdirectory: String) throws -> String {
        try FileManager.default.contentsOfDirectory(
            at: sourcesDir.appendingPathComponent(subdirectory),
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { code(try String(contentsOf: $0, encoding: .utf8)) }
            .joined(separator: "\n")
    }

    // MARK: - Both directions on the registry

    /// Every listed producer is declared and actually called by a screen.
    ///
    /// A producer nothing calls is a refusal nobody can be shown, which looks
    /// exactly like one that works (L46).
    func testEveryListedProducerIsDeclaredAndUsed() throws {
        let services = try code(in: "Services")
        let views = try code(in: "Views")

        var problems: [String] = []
        for producer in Self.refusalProducers {
            let fn = producer.components(separatedBy: ".").last ?? producer
            if !services.contains("func \(fn)") {
                problems.append("\(producer) is not declared in Services any more")
            }
            if !views.contains(producer) {
                problems.append("\(producer) is not called by any screen, so it can never be seen")
            }
        }

        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: - The shape that shipped

    /// The stage strip, because that is where it shipped and it is on every screen.
    func testTheStageStripDrawsItsRefusalRatherThanHidingItOnHover() throws {
        let source = code(try String(
            contentsOf: sourcesDir.appendingPathComponent("Views/ProgramUploadView.swift"),
            encoding: .utf8))

        XCTAssertTrue(source.contains("RefusalNote("),
                      "the stage strip has to draw its refusal, not only offer it on hover")
        XCTAssertFalse(source.contains(".disabled(blocked != nil"),
                       "a blocked step stays pressable so it can explain itself; only "
                       + "\"you are here\" is inert")
    }

    /// The new event sheet, which had no refusal at all.
    func testTheNewEventSheetDrawsWhatIsMissing() throws {
        let source = code(try String(
            contentsOf: sourcesDir.appendingPathComponent("Views/NewEventSheet.swift"),
            encoding: .utf8))

        XCTAssertTrue(source.contains("RefusalNote("),
                      "a greyed Create Event button has to say which field is empty")
        XCTAssertTrue(source.contains("NewEventValidation.refusal"),
                      "and the disabled state and the sentence have to come from one predicate")
    }

    /// `RefusalNote` exists once and is shared, rather than each screen growing
    /// its own quiet explanatory line that drifts from the others.
    func testTheRefusalLineHasOneImplementation() throws {
        let views = try code(in: "Views")
        let declarations = views.components(separatedBy: "struct RefusalNote").count - 1
        XCTAssertEqual(declarations, 1,
                       "RefusalNote is declared \(declarations) times; it is meant to be shared")
    }
}
