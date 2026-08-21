import XCTest
import SwiftUI
import AppKit

/// #758: nothing in PostRoll showed a frame the way Instagram will.
///
/// The caption review screen drew each preview as a clean rectangle, with no
/// status bar, no Dynamic Island, no caption band and no action rail. That gap
/// is how #752 survived: the show title had been printed under the clock on
/// every scroll reel published, every local render looked perfect, and the only
/// detector was Dan seeing a live story on his phone.
///
/// The bands are the measurement from #753 and #761, taken off two published
/// reels on Dan's iPhone, so what the overlay draws is what was measured rather
/// than an impression of it.
@MainActor
final class PhoneChromeOverlayTests: XCTestCase {

    private let canvas = PhoneSafeArea.canvas

    // MARK: - The geometry

    func testAtTheCanvasSizeTheBandsAreTheTokensThemselves() {
        let bands = PhoneChromeBands(in: canvas)

        XCTAssertEqual(bands.top.height, PhoneSafeArea.top, accuracy: 0.01)
        XCTAssertEqual(bands.bottom.height, PhoneSafeArea.bottom, accuracy: 0.01)
        XCTAssertEqual(bands.rail.width, PhoneSafeArea.right, accuracy: 0.01)
    }

    func testTheBandsScaleWithTheViewTheyAreDrawnIn() {
        // A preview on the caption screen is a few hundred points tall, not
        // 1920, so a band drawn at its token value would swallow the whole
        // thumbnail and report every template as broken.
        let half = CGSize(width: canvas.width / 2, height: canvas.height / 2)

        let bands = PhoneChromeBands(in: half)

        XCTAssertEqual(bands.top.height, PhoneSafeArea.top / 2, accuracy: 0.01)
        XCTAssertEqual(bands.bottom.height, PhoneSafeArea.bottom / 2, accuracy: 0.01)
        XCTAssertEqual(bands.rail.width, PhoneSafeArea.right / 2, accuracy: 0.01)
    }

    func testTheBandsSitAtTheEdgesTheyDescribe() {
        let size = CGSize(width: 270, height: 480)
        let bands = PhoneChromeBands(in: size)

        XCTAssertEqual(bands.top.minY, 0, accuracy: 0.01)
        XCTAssertEqual(bands.top.width, size.width, accuracy: 0.01)
        XCTAssertEqual(bands.bottom.maxY, size.height, accuracy: 0.01)
        XCTAssertEqual(bands.bottom.width, size.width, accuracy: 0.01)
        XCTAssertEqual(bands.rail.maxX, size.width, accuracy: 0.01)
        XCTAssertEqual(bands.rail.maxY, size.height, accuracy: 0.01)
    }

    func testTheRailStartsWhereItWasMeasuredToStart() {
        // A rail over the bottom half, not a whole edge. Drawing it full height
        // would report a template's top right corner as covered when nothing
        // covers it, and the first false alarm is what gets an overlay switched
        // off (L36).
        let size = CGSize(width: 270, height: 480)

        let bands = PhoneChromeBands(in: size)

        XCTAssertEqual(bands.rail.minY, size.height * PhoneSafeArea.rightFrom,
                       accuracy: 0.01)
        XCTAssertGreaterThan(bands.rail.minY, 0,
                             "the rail is drawn from the very top, which is not where it is")
    }

    func testNoBandReachesOutsideTheFrame() {
        for size in [CGSize(width: 90, height: 160), CGSize(width: 1080, height: 1920)] {
            let bands = PhoneChromeBands(in: size)
            for (name, rect) in [("top", bands.top), ("bottom", bands.bottom),
                                 ("rail", bands.rail)] {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect),
                              "the \(name) band leaves the \(size) frame it is drawn in")
            }
        }
    }

    func testAFrameWithNoHeightIsRefusedRatherThanDividedBy() {
        // SwiftUI hands a GeometryReader zero on the first layout pass more
        // often than anyone expects, and a scale computed from it is either a
        // crash or a NaN that silently paints nothing (L67).
        let bands = PhoneChromeBands(in: CGSize(width: 0, height: 0))

        XCTAssertTrue(bands.isEmpty)
        XCTAssertEqual(bands.top, .zero)
    }

    // MARK: - The overlay draws

    func testTheOverlayPutsSomethingOnThePage() throws {
        let size = CGSize(width: 270, height: 480)
        let plain = try WordFootprint.hosted(
            Color.warmDark.frame(width: size.width, height: size.height),
            size: size, wordless: false)
        let marked = try WordFootprint.hosted(
            Color.warmDark
                .frame(width: size.width, height: size.height)
                .overlay { PhoneChromeOverlay() },
            size: size, wordless: false)

        // Measured against the SAME surface without it, because any quantity
        // computed over a whole surface counts the fill too (L146).
        XCTAssertGreaterThan(WordFootprint.share(marked, plain), 0.02,
                             "the overlay drew nothing anybody could see")
    }

    func testTheOverlayLeavesTheMiddleOfTheFrameAlone() throws {
        // What the preview is FOR is the photograph. An overlay that dimmed the
        // whole frame would be switched off within a day and the gap would be
        // back.
        let size = CGSize(width: 270, height: 480)
        let bands = PhoneChromeBands(in: size)

        XCTAssertGreaterThan(bands.top.maxY, 0)
        XCTAssertLessThan(bands.top.maxY, bands.bottom.minY,
                          "the top and bottom bands meet, so the whole frame is covered")
        let clearHeight = bands.bottom.minY - bands.top.maxY
        XCTAssertGreaterThan(clearHeight / size.height, 0.75,
                             "the bands cover more than a quarter of the frame between them")
    }

    // MARK: - The preference

    func testTheOverlayIsOnUntilItIsTurnedOff() {
        // The default is what closes #752's gap. Off by default would leave the
        // check present and inert, which is the shape of a safeguard nobody
        // benefits from (L65, L72 in reverse: here the SAFE state is on).
        let defaults = scratchDefaults()

        XCTAssertTrue(PhoneChromePreference.isOn(in: defaults))
    }

    func testTurningItOffIsRemembered() {
        let defaults = scratchDefaults()

        PhoneChromePreference.set(false, in: defaults)

        XCTAssertFalse(PhoneChromePreference.isOn(in: defaults))
    }

    func testTurningItBackOnIsRememberedToo() {
        // The other direction, because a setter that only ever wrote `false`
        // would pass the test above and strand anybody who turned it off.
        let defaults = scratchDefaults()
        PhoneChromePreference.set(false, in: defaults)

        PhoneChromePreference.set(true, in: defaults)

        XCTAssertTrue(PhoneChromePreference.isOn(in: defaults))
    }

    /// A suite of this test's own, never the app's (#734).
    private func scratchDefaults() -> UserDefaults {
        let name = "com.dwphotony.PostRoll.phonechrome.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
}
