import XCTest

/// A sweep too slow to be one test, split into classes rather than methods
/// (#1257).
///
/// ## Why classes and not methods
///
/// `xcodebuild` packs a parallel run by CLASS, so a class can never finish
/// faster than its longest test and a 51 second sweep sets the floor for the
/// whole run however many workers there are. Measured 2026-09-04 on the 12 core
/// Mac: 296.9s of test bodies over 315 classes, and one test,
/// `UnseenSurfaceTests.testNoMeasuredStateHidesItsWordsFromTheRenderer`, held
/// 51.0s of it. Perfect packing at 12 workers would be 24.7s, so that single
/// test was twice the whole theoretical bound.
///
/// Splitting it into three methods of one class would have changed nothing: the
/// class is the unit that gets dealt.
///
/// ## Why the slices are derived
///
/// By `index % count`, so every case lands in exactly one slice and a case
/// added later joins one without anybody editing a list. A hand written split
/// covers what somebody remembered to add, and the ones anybody remembers are
/// the ones already safe (L96, L41).
///
/// `EverySweepCoversItsWholeSetTests` holds that: it asserts the slices are a
/// partition, every item in exactly one, none twice, none lost (L517).
///
/// ## Using it
///
/// Subclass, give each subclass its own `slice`, and read `mine(of:)` inside
/// the test. The BASE class runs nothing: `defaultTestSuite` is empty for it,
/// or the sweep would run a fourth time over the whole set and the split would
/// have cost time rather than saved it.
class SweptInSlices: XCTestCase {

    /// Which share this subclass takes. Negative means "this is the base", and
    /// the base runs nothing.
    class var slice: Int { -1 }

    /// How many shares the sweep is cut into.
    ///
    /// Three, measured rather than picked: it takes the heaviest class here
    /// from 55.2s to about 19s, which puts it under the next heaviest class
    /// that is not swept at all, so a fourth slice would be cutting something
    /// that is no longer the floor (L172).
    class var slices: Int { 2 }

    /// An empty suite for the base, so the sweep runs once per SLICE and not
    /// once more over everything.
    ///
    /// Without this the base class is a test class like any other and XCTest
    /// runs its inherited methods too, which would leave the original whole
    /// sweep in the run beside the three parts of it.
    override class var defaultTestSuite: XCTestSuite {
        slice < 0 ? XCTestSuite(name: "\(self) (base, runs nothing)")
                  : super.defaultTestSuite
    }

    /// This slice's share of `items`.
    func mine<T>(of items: [T]) -> [T] {
        Self.share(slice: Self.slice, of: Self.slices, in: items)
    }

    /// The share itself, as a pure function so a test can check the partition
    /// without instantiating anything.
    static func share<T>(slice: Int, of count: Int, in items: [T]) -> [T] {
        guard count > 0, slice >= 0 else { return [] }
        return items.enumerated()
            .filter { $0.offset % count == slice }
            .map(\.element)
    }
}
