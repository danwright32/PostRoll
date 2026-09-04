import XCTest

/// A sweep cut into slices still covers everything (#1257).
///
/// Splitting a sweep to make it faster is only free while the slices are a
/// PARTITION: every case in exactly one, none twice, none lost. A slice that
/// quietly stopped covering some states would report a clean sweep over a set
/// it no longer holds, which is the same answer a working sweep gives (L98,
/// L517).
///
/// The slices are derived by `index % count` rather than listed, so a state
/// added later joins one without anybody editing anything. This is what says
/// that derivation is right, and that the classes really do declare the slices
/// it produces.
@MainActor
final class EverySweepCoversItsWholeSetTests: XCTestCase {

    /// Every sweep split this way, and the set each one is over.
    ///
    /// Read from the classes rather than listed beside them: `slice` and
    /// `slices` are what the run actually uses, so a class whose slice number
    /// was mistyped fails here rather than silently sweeping the same share
    /// twice (L70).
    private var sweeps: [(name: String, count: Int, slices: [Int], size: Int)] {
        [
            ("UnseenStateSweep",
             UnseenStateSweep.slices,
             [UnseenStateSweepA.slice, UnseenStateSweepB.slice],
             BannerLegibilityTests.measuredStates.count),
            ("BannerSweep",
             BannerSweep.slices,
             [BannerSweepA.slice, BannerSweepB.slice],
             BannerLegibilityTests.measuredStates.count),
            ("ScreensDrawSomething",
             ScreensDrawSomething.slices,
             [ScreensDrawSomethingA.slice, ScreensDrawSomethingB.slice],
             HostedControlLegibilityTests().wholeScreens.count),
        ]
    }

    func testEveryCaseLandsInExactlyOneSlice() {
        for sweep in sweeps {
            let items = Array(0..<sweep.size)
            var seen: [Int: Int] = [:]
            for slice in sweep.slices {
                for item in SweptInSlices.share(slice: slice, of: sweep.count,
                                                in: items) {
                    seen[item, default: 0] += 1
                }
            }

            let missing = items.filter { seen[$0] == nil }
            let twice = items.filter { (seen[$0] ?? 0) > 1 }
            XCTAssertTrue(missing.isEmpty,
                          "\(sweep.name) sweeps \(sweep.size) cases and "
                          + "\(missing.count) of them are in no slice, so "
                          + "nothing checks them and the sweep still reports "
                          + "clean")
            XCTAssertTrue(twice.isEmpty,
                          "\(sweep.name) checks \(twice.count) cases twice, so "
                          + "the split cost time rather than saving it")
        }
    }

    func testTheSlicesAreTheOnesTheClassesDeclare() {
        for sweep in sweeps {
            XCTAssertEqual(Set(sweep.slices), Set(0..<sweep.count),
                           "\(sweep.name) is cut into \(sweep.count) shares and "
                           + "the classes declare \(sweep.slices.sorted()), so "
                           + "either a share has no class or two classes hold "
                           + "the same one")
        }
    }

    func testTheBaseClassOfASweepRunsNothing() {
        // Without this the base is a test class like any other and XCTest runs
        // its inherited methods too, leaving the ORIGINAL whole sweep in the
        // run beside the three parts of it: the split would then cost time
        // rather than saving it, and every check here would still pass.
        for base in [UnseenStateSweep.self, BannerSweep.self,
                     ScreensDrawSomething.self] as [SweptInSlices.Type] {
            XCTAssertEqual(base.defaultTestSuite.tests.count, 0,
                           "\(base) runs the sweep as well as its slices, so "
                           + "the split costs time rather than saving it")
            XCTAssertLessThan(base.slice, 0,
                              "\(base) declares a real slice, so it takes a "
                              + "share as well as running nothing")
        }
    }

    func testASliceOfNothingIsEmptyRatherThanEverything() {
        // The refusal, asserted rather than assumed. A share function that
        // returned the whole set for an unset slice would make the base sweep
        // everything while reading as empty (L11).
        XCTAssertEqual(SweptInSlices.share(slice: -1, of: 3, in: [1, 2, 3]), [])
        XCTAssertEqual(SweptInSlices.share(slice: 0, of: 0, in: [1, 2, 3]), [])
    }

    func testTheShareIsTheOneTheSweepsActuallyGet() {
        // The reading every check above rests on, asserted directly rather than
        // only through them (L178).
        let items = Array(1...7)

        XCTAssertEqual(SweptInSlices.share(slice: 0, of: 3, in: items), [1, 4, 7])
        XCTAssertEqual(SweptInSlices.share(slice: 1, of: 3, in: items), [2, 5])
        XCTAssertEqual(SweptInSlices.share(slice: 2, of: 3, in: items), [3, 6])
    }
}
