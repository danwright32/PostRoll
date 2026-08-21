import XCTest
import SwiftUI
import AppKit

/// #751: what the `ImageRenderer` harness cannot see, named rather than
/// reported as measured.
///
/// Measured while building #743: `ImageRenderer`, which `BannerLegibilityTests`
/// draws every notice with, renders a `ScrollView` as entirely blank whatever
/// it holds. The same rows measured 0.034 of the page on their own and 0.000
/// inside one. `FadingScrollView`, which is our own wrapper around one,
/// behaves identically.
///
/// It matters because a surface holding a scroll region is then only PARTLY
/// measured and nothing says so: the words the harness counts are the ones
/// outside the scroll, so the check passes while everything inside it was
/// never drawn, and a blank region and a correctly drawn one are the same
/// answer (L98). `CaptionReviewNotices` hit this and had to be measured
/// through AppKit hosting instead, which does draw it.
///
/// Two checks over every measured state, because they fail in different ways:
///
/// * the MEASUREMENT, which renders each state both ways and holds the two to
///   each other. It knows nothing about type names, so it covers any container
///   at all, including one nobody has thought of, but it can only see a state
///   whose hidden part is a large share of its words.
/// * the NAME check, which reads the type tree. It catches a scroll region
///   holding one line as readily as one holding twenty, but it can only see a
///   container the view stores rather than one built inside a `body`, and it
///   only knows the containers listed below.
///
/// Neither is sufficient on its own and both are cheap, so both run.
@MainActor
final class UnseenSurfaceTests: XCTestCase {

    /// One frame for every render here, so a difference between two of them is
    /// the renderer rather than the layout. Both renderers are handed exactly
    /// this, and the height clips both alike.
    private static let frame = CGSize(width: 520, height: 300)

    /// How much of what AppKit draws `ImageRenderer` has to draw too.
    ///
    /// Measured, not guessed. Across the forty banner states in
    /// `BannerLegibilityTests.measuredStates` the ratio runs from 0.56 to 0.69,
    /// the spread being antialiasing at two scales rather than missing words. A
    /// surface whose content sits inside a scroll region measures 0.00. This
    /// sits far below the real band and far above the defect, rather than
    /// inside the dense middle where a small shift would carry states across
    /// it (L172).
    private static let seenEnough = 0.30

    /// The containers whose contents `ImageRenderer` does not draw.
    ///
    /// Calibrated rather than assumed: `testEveryNamedContainerIsGenuinelyOne
    /// TheRendererCannotSee` renders each one and fails if the renderer has
    /// learned to draw it, so an entry here can never become a rule about
    /// something that works (L1).
    private static let unseenContainers = ["ScrollView", "FadingScrollView", "List"]

    // MARK: - Rendering

    /// Six lines of ordinary notice copy. Enough that a page drawing them and a
    /// page drawing none of them are nowhere near each other.
    private func rows() -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(0..<6, id: \.self) { index in
                Text("A sentence of ordinary notice copy, number \(index).")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmDark)
            }
        }
    }

    /// On `Color.cream` and padded, which is how `BannerLegibilityTests` frames
    /// every state it measures. Rendered any other way this would be measuring
    /// a page the app never shows.
    private func framed(_ view: some View) -> some View {
        ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: Self.frame.width, height: Self.frame.height)
    }

    /// The share of the page that is type, as `ImageRenderer` draws it.
    private func byRenderer(_ view: some View) throws -> Double {
        let page = framed(view)
        return WordFootprint.share(try WordFootprint.imageRendered(page, wordless: false),
                                   try WordFootprint.imageRendered(page, wordless: true))
    }

    /// The same, as AppKit draws it.
    private func byHosting(_ view: some View) throws -> Double {
        let page = framed(view)
        return WordFootprint.share(try WordFootprint.hosted(page, size: Self.frame, wordless: false),
                                   try WordFootprint.hosted(page, size: Self.frame, wordless: true))
    }

    // MARK: - The blindness itself, recorded

    func testTheRendererDrawsNothingInsideAScrollRegion() throws {
        let bare = try byRenderer(rows())
        let scrolled = try byRenderer(ScrollView { self.rows() })

        // The positive control first: without it, "the scrolled one measured
        // nothing" is satisfied by a fixture that had nothing to draw (L159).
        XCTAssertGreaterThan(bare, WordFootprint.drawn, """
            the fixture rows measure \(String(format: "%.4f", bare)) on their own, which is \
            below the floor, so this proves nothing about what a scroll region does to them
            """)
        XCTAssertLessThan(scrolled, WordFootprint.drawn, """
            the same rows inside a ScrollView measure \(String(format: "%.4f", scrolled)) \
            through ImageRenderer, which is above the floor. If ImageRenderer has learned \
            to draw a scroll region, the sweeps in this file are guarding against something \
            that no longer happens and the notices measured through it can carry one again.
            """)
    }

    func testHostingDrawsWhatTheRendererCannotSee() throws {
        // The remedy, measured rather than believed: this is the whole reason
        // the reading screens are hosted rather than image-rendered.
        let bare = try byHosting(rows())
        let scrolled = try byHosting(ScrollView { self.rows() })

        XCTAssertGreaterThan(scrolled, WordFootprint.drawn,
                             "AppKit hosting draws nothing inside a scroll region either, so "
                             + "the screens moved onto it are no better measured than before")
        XCTAssertEqual(scrolled, bare, accuracy: 0.005,
                       "hosting draws a different amount of type inside a scroll region than "
                       + "outside one, so the two cannot be held to each other")
    }

    func testEveryNamedContainerIsGenuinelyOneTheRendererCannotSee() throws {
        var drawnAfterAll: [String] = []
        for name in Self.unseenContainers {
            let share: Double
            switch name {
            case "ScrollView": share = try byRenderer(ScrollView { self.rows() })
            case "FadingScrollView": share = try byRenderer(FadingScrollView { self.rows() })
            case "List": share = try byRenderer(List { self.rows() })
            default:
                return XCTFail("\(name) is listed as unseen and nothing here renders it, so "
                               + "its entry is a claim no measurement stands behind")
            }
            if share >= WordFootprint.drawn { drawnAfterAll.append(name) }
        }

        XCTAssertEqual(drawnAfterAll, [], """
            these containers are listed as ones ImageRenderer cannot draw inside, and it \
            drew their contents: \(drawnAfterAll). An entry that names something that works \
            makes the sweep refuse a surface for no reason.
            """)
    }

    // MARK: - The sweep

    func testNoMeasuredStateHidesItsWordsFromTheRenderer() throws {
        var unseen: [String] = []
        for state in BannerLegibilityTests.measuredStates {
            let rendered = try byRenderer(state.view)
            let hosted = try byHosting(state.view)
            guard hosted > WordFootprint.drawn else { continue }
            if rendered / hosted < Self.seenEnough {
                unseen.append("\(state.name) "
                              + "(\(String(format: "%.4f", rendered)) of "
                              + "\(String(format: "%.4f", hosted)))")
            }
        }

        XCTAssertEqual(unseen, [], """
            ImageRenderer draws far less of these surfaces than AppKit does, so \
            BannerLegibilityTests is measuring part of them and reporting the whole: \
            \(unseen). The commonest cause is a scroll region, whose contents ImageRenderer \
            renders as nothing at all. Measure them through WordFootprint.hosted the way \
            HostedControlLegibilityTests does.
            """)
    }

    func testNoMeasuredStateHoldsAContainerTheRendererCannotSee() throws {
        var holding: [String] = []
        for state in BannerLegibilityTests.measuredStates {
            let described = String(describing: state.view)
            let found = Self.unseenContainers.filter { described.contains($0) }
            if !found.isEmpty { holding.append("\(state.name): \(found.joined(separator: ", "))") }
        }

        XCTAssertEqual(holding, [], """
            these measured states hold a container ImageRenderer draws as blank, so whatever \
            is inside it was never drawn and the check that measured them passed on the ink \
            around it: \(holding). Measure them through WordFootprint.hosted instead.
            """)
    }

    func testTheContainerDetectorSeesOneWhenItIsThere() {
        // The sweep above asserts an absence, and an absence is also what a
        // detector that sees nothing at all reports (L159). This is the same
        // reading against a state that genuinely holds one.
        let described = String(describing: AnyView(ScrollView { self.rows() }))

        XCTAssertTrue(Self.unseenContainers.contains { described.contains($0) },
                      "the type tree of a view built around a ScrollView does not name one, "
                      + "so the sweep above is reading nothing and would pass on any state")
    }
}
