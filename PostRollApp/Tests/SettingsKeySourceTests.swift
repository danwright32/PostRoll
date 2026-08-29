import XCTest

/// Where the Settings screen gets the stored API key from (#918).
///
/// The screen has to be renderable for review, and it reads the key out of the
/// real macOS keychain the moment it is built. Rendering it as it stood would
/// have put a live secret read inside the test suite, on every run and on every
/// machine including CI. Nothing else in this project does that: every existing
/// test around the key hands one in rather than reading the store (see
/// `APIKeyDeliveryTests`, which passes its own), and that was deliberate (L2).
///
/// So the source becomes a value. The app uses `.keychain` and behaves exactly
/// as before; a render hands in `.fixed`. Nothing about how the key is stored,
/// saved or delivered changes.
///
/// A named value rather than a closure, because the DEFAULT is the part worth
/// asserting: a seam whose default silently became the fake one would be a test
/// setup leaking into the app, and two functions cannot be compared to catch it.
final class SettingsKeySourceTests: XCTestCase {

    func testTheAppReadsTheRealKeychain() {
        XCTAssertEqual(SettingsView().keySource, .keychain,
                       "the default is what ships, so it is the one that has "
                       + "to be pinned: a seam defaulting to a fixture would "
                       + "leave the real screen reading nothing")
    }

    func testAFixedSourceHandsBackWhatItWasGiven() {
        XCTAssertEqual(SettingsView.KeySource.fixed("sk-ant-fake").read(),
                       "sk-ant-fake")
    }

    func testAFixedSourceCanStandForNoKeyStored() {
        XCTAssertNil(SettingsView.KeySource.fixed(nil).read(),
                     "a machine with no key saved is a real state the screen "
                     + "has to be reviewable in, and it is the first-run one")
    }

    /// The point of the whole change: constructing the screen for a render must
    /// not reach the keychain. Asserted through the source rather than by
    /// watching for a call, because the source IS what decides.
    func testARenderedScreenIsNotPointedAtTheKeychain() {
        let underReview = SettingsView(keySource: .fixed("sk-ant-example"))

        XCTAssertNotEqual(underReview.keySource, .keychain)
        XCTAssertEqual(underReview.keySource, .fixed("sk-ant-example"))
    }
}
