import XCTest
import SwiftUI
import AppKit

/// The two banner sweeps out of `BannerLegibilityTests`, cut into slices
/// (#1257).
///
/// Together they held 30.7 of that class's 32.7 seconds, measured on the 12
/// core Mac on 2026-09-04, out of 296.9 seconds of test bodies in the whole
/// suite. `xcodebuild` packs a parallel run by CLASS, so a class can never
/// finish faster than its longest test, and splitting them into more METHODS of
/// one class would have changed nothing.
///
/// They call `BannerLegibilityTests`'s own `render` and `wordShare` rather than
/// carrying a copy: one implementation and one memo, because sharing the data
/// while copying the code that applies it is not consolidation (L370).
@MainActor
class BannerSweep: SweptInSlices {

    var states: [(name: String, view: AnyView)] {
        mine(of: BannerLegibilityTests.measuredStates)
    }

    /// A slice that swept nothing objects to nothing (L98). Asserted in each
    /// test rather than once, because a test that never ran is what an empty
    /// slice produces and there is nothing to hang a shared check on.
    private func swept() -> [(name: String, view: AnyView)] {
        let mine = states
        XCTAssertFalse(mine.isEmpty,
                       "this slice holds no states, so it reports every banner "
                       + "it covers as legible while covering none")
        return mine
    }

    func testEveryBannerActuallyDrawsItsMessage() throws {
        for state in swept() {
            let share = try BannerLegibilityTests.wordShare(of: state)
            XCTAssertGreaterThan(share, WordFootprint.drawn, """
                Switching every word off the "\(state.name)" banner changed \
                \(String(format: "%.4f", share)) of the render, which is nothing. Its \
                message is in the view tree and not on the screen, and the fill, the \
                border and the buttons this surface paints for itself would keep a flat \
                ink threshold happy without it (L141). Either the words are drawn in the \
                colour of what is behind them, or ImageRenderer is not drawing them at \
                all, in which case the state belongs in HostedControlLegibilityTests \
                where AppKit hosts it.
                """)
        }
    }

    func testEveryBannerStillDrawsItsMessageWhenNarrow() throws {
        for state in swept() {
            let share = try BannerLegibilityTests.wordShare(of: state, width: 300)
            XCTAssertGreaterThan(share, WordFootprint.drawn,
                                 "the \"\(state.name)\" banner lost its message at 300pt wide")
        }
    }
}

@MainActor
final class BannerSweepA: BannerSweep { override nonisolated class var slice: Int { 0 } }
@MainActor
final class BannerSweepB: BannerSweep { override nonisolated class var slice: Int { 1 } }
