import XCTest
import SwiftUI

/// #1169: the retry control, drawn rather than merely present.
///
/// #1160's tests cover which repair states invite a retry, which markers a
/// retry names, and what its result sentence says. None of them draws anything.
/// A control can be in the view tree, correctly named to a screen reader, and
/// invisible on screen (L213, L231), and this one is unusually exposed to that
/// going unnoticed: it appears only after a repair was `blocked` or
/// `not_reached`, which needs the model to have been unreachable or a photograph
/// unreadable, so Dan could go months without tripping it by hand.
///
/// Measured the way every other surface in this suite is: render the panel,
/// render it again with its words switched off, and compare. What differs is
/// the type and nothing else, so the chrome the panel paints for itself is not
/// in the number (L141, L146).
@MainActor
final class BlogRetryControlLegibilityTests: XCTestCase {

    private func finding(repair: String, target: String) -> QualityFinding {
        QualityFinding(
            code: "alt_text_length",
            message: "Alt text must be 15 to 25 words.",
            detail: "\(target): 9 words. A singer at a microphone",
            repair: repair, target: target)
    }

    /// A draft carrying findings in a given repair state.
    private func blog(_ findings: [QualityFinding]) -> BlogOutput {
        var out = BlogOutput(title: "A night that ran long", body: "Prose.")
        out.photoCount = findings.count
        out.findings = findings
        out.findingsBody = "Prose."
        return out
    }

    private func panel(_ blog: BlogOutput,
                       retryNote: String? = nil,
                       onRetry: (([String]) -> Void)? = { _ in }) -> some View {
        BlogSection(
            blog: .constant(blog),
            photoCount: blog.photoCount,
            isExpanded: true,
            onToggle: {},
            onRevise: { _, _ in },
            onRetryRepairs: onRetry,
            retryNote: retryNote)
    }

    /// A canvas TALLER than the panel needs, anchored at the top.
    ///
    /// The first version pinned a 640pt height and centred the panel in it, and
    /// the note test failed in the revealing direction: adding a sentence made
    /// the measured type go DOWN, from 0.0345 to 0.0328. Content that grows in a
    /// frame it already overflows pushes type off BOTH ends, so the number was
    /// measuring how much the panel had been clipped rather than what it drew
    /// (L146). Nothing may be cropped by adding a line, or the comparison is
    /// between two different croppings of the same panel.
    private func render(_ view: some View, wordless: Bool = false) throws
        -> NSBitmapImageRep {
        let size = CGSize(width: 520, height: 1400)
        return try WordFootprint.hosted(
            ZStack(alignment: .top) {
                Color.cream
                view.frame(width: size.width)
            }.frame(width: size.width, height: size.height, alignment: .top),
            size: size, wordless: wordless)
    }

    private func footprint(_ view: some View) throws -> Double {
        WordFootprint.share(try render(view), try render(view, wordless: true))
    }

    // MARK: - It draws

    func testTheRetryControlDrawsItsWords() throws {
        let with = try footprint(panel(blog([
            finding(repair: "blocked", target: "a.jpg"),
            finding(repair: "blocked", target: "b.jpg"),
        ])))
        // The same panel with the control withheld, so the difference is the
        // control's own type and not the panel's.
        let without = try footprint(panel(blog([
            finding(repair: "blocked", target: "a.jpg"),
            finding(repair: "blocked", target: "b.jpg"),
        ]), onRetry: nil))

        print(String(format: "  %.4f with the control, %.4f without", with, without))
        XCTAssertGreaterThan(with, without + WordFootprint.drawn, """
            Adding the retry control changed \(String(format: "%.4f", with - without)) \
            of the render, which is nothing, so the words Dan is meant to read \
            before pressing it are not on the page.
            """)
    }

    func testTheResultSentenceDrawsItsWords() throws {
        let draft = blog([finding(repair: "blocked", target: "a.jpg")])
        let quiet = try footprint(panel(draft))
        let said = try footprint(panel(draft, retryNote:
            "Tried 1 again and the checks still refused them, so pressing "
          + "again will not help."))

        print(String(format: "  %.4f without the note, %.4f with it", quiet, said))
        XCTAssertGreaterThan(said, quiet + WordFootprint.drawn, """
            The sentence saying what the retry DID drew nothing, so a retry \
            that rewrote none of what it tried looks exactly like one that \
            rewrote everything, which is what #1160 exists to prevent.
            """)
    }

    // MARK: - It stays away when there is nothing to retry

    func testNothingIsDrawnWhenNoFindingInvitesARetry() throws {
        // `tried` says the app will not get it next time either. Offering a
        // retry there spends a paid call to reproduce the same answer.
        let draft = blog([finding(repair: "tried", target: "a.jpg")])
        let offered = try footprint(panel(draft))
        let withheld = try footprint(panel(draft, onRetry: nil))

        XCTAssertEqual(offered, withheld, accuracy: WordFootprint.drawn, """
            The panel drew something extra for a finding no retry can help, \
            which is the dead control this issue exists to remove, pointing \
            the other way.
            """)
    }

    // MARK: - The control on this measurement

    func testTheMeasurementCanTellTheTwoApart() throws {
        // Without this, every assertion above could be comparing two identical
        // renders and reporting agreement as proof (L159).
        let draft = blog([finding(repair: "blocked", target: "a.jpg")])
        let drawn = try footprint(panel(draft))

        XCTAssertGreaterThan(drawn, WordFootprint.drawn,
                             "the panel drew no type at all, so nothing above "
                           + "is measuring what it claims to")
    }
}
