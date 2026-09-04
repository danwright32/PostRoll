import XCTest
import SwiftUI
import AppKit

/// The sweep out of `UnseenSurfaceTests`, cut into slices (#1257).
///
/// It asks, of every state `BannerLegibilityTests` measures, whether
/// `ImageRenderer` draws enough of it for that measurement to be about the whole
/// surface. A state whose content sits inside a scroll region measures 0.00
/// through the renderer and whatever the ink around it happens to be through the
/// check, so the check passes on a surface it never saw (L98).
///
/// ## Why it moved out of that file
///
/// It was one test taking 51.0 of the suite's 296.9 seconds of test bodies,
/// measured on the 12 core Mac on 2026-09-04. `xcodebuild` packs a parallel run
/// by CLASS, so a class can never finish faster than its longest test: perfect
/// packing at twelve workers would have been 24.7s, and this one test was twice
/// that on its own.
///
/// Splitting it into three METHODS of one class would have changed nothing,
/// which is why it is three classes. The slices are derived by
/// `index % count`, so a state added to `measuredStates` joins one without
/// anybody editing anything, and `EverySweepCoversItsWholeSetTests` holds the
/// three to being a partition of the whole set.
@MainActor
class UnseenStateSweep: SweptInSlices {

    /// The same frame both renderers are handed, so a difference between two
    /// readings is the renderer rather than the layout.
    static let frame = CGSize(width: 520, height: 300)

    /// How much of what AppKit draws `ImageRenderer` has to draw too.
    ///
    /// Measured, not guessed. Across the banner states the ratio runs from 0.56
    /// to 0.69, the spread being antialiasing at two scales rather than missing
    /// words. A surface inside a scroll region measures 0.00. This sits far
    /// below the real band and far above the defect, rather than inside the
    /// dense middle where a small shift would carry states across it (L172).
    static let seenEnough = 0.30

    /// On `Color.cream` and padded, which is how `BannerLegibilityTests` frames
    /// every state it measures. Rendered any other way this would be measuring
    /// a page the app never shows.
    private func framed(_ view: some View) -> some View {
        ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: Self.frame.width, height: Self.frame.height)
    }

    private func byRenderer(_ view: some View) throws -> Double {
        let page = framed(view)
        return WordFootprint.share(try WordFootprint.imageRendered(page, wordless: false),
                                   try WordFootprint.imageRendered(page, wordless: true))
    }

    private func byHosting(_ view: some View) throws -> Double {
        let page = framed(view)
        return WordFootprint.share(
            try WordFootprint.hosted(page, size: Self.frame, wordless: false),
            try WordFootprint.hosted(page, size: Self.frame, wordless: true))
    }

    func testNoMeasuredStateHidesItsWordsFromTheRenderer() throws {
        let states = mine(of: BannerLegibilityTests.measuredStates)
        XCTAssertFalse(states.isEmpty,
                       "this slice swept nothing, so it reports every state it "
                       + "holds as visible while holding none (L98)")

        var unseen: [String] = []
        for state in states {
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
}

@MainActor
final class UnseenStateSweepA: UnseenStateSweep { override nonisolated class var slice: Int { 0 } }
@MainActor
final class UnseenStateSweepB: UnseenStateSweep { override nonisolated class var slice: Int { 1 } }
