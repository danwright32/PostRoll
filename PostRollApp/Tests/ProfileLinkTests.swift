import XCTest

/// #973: one way to reach an account's Instagram profile.
///
/// The collaborator panel listed each candidate's handle as plain text, so
/// filling in the numbers behind "Add numbers" meant reading the handle off the
/// screen, switching to a browser and typing it in by hand, once per account.
/// The sheet itself says "Open their profile and read these off a few recent
/// posts", so opening the profile is the expected next step and the app made it
/// a manual retype.
///
/// The programme review screen already opens a performer's profile, from a URL
/// the research step stored and verified. Those are two ways of reaching the
/// same place, so there is one piece of behaviour here and both screens call
/// it, rather than a second implementation growing in the panel.
final class ProfileLinkTests: XCTestCase {

    // MARK: - Building the address from a handle

    /// A stored handle can be any of these three, and `bareUsername` is the one
    /// thing that turns all three into a path component. Interpolating the
    /// stored string would put "@jane" or a whole URL into the path.
    func testTheSameAddressIsBuiltFromEverySpellingOfOneHandle() {
        let expected = URL(string: "https://www.instagram.com/jane/")
        XCTAssertEqual(ProfileLink.url(handle: "jane"), expected)
        XCTAssertEqual(ProfileLink.url(handle: "@jane"), expected)
        XCTAssertEqual(ProfileLink.url(handle: "https://instagram.com/jane/"), expected)
    }

    // MARK: - Refusing what is not an account

    /// A dead link that looks live is worse than no link. `isRealHandle` is the
    /// read time linkability test the app already uses on nine other surfaces:
    /// shaped like a username AND not one of the sentinels recorded when a
    /// lookup found nothing.
    func testASentinelIsNotLinkable() {
        XCTAssertNil(ProfileLink.url(handle: "unknown"))
    }

    func testADisplayNameWithASpaceIsNotLinkable() {
        XCTAssertNil(ProfileLink.url(handle: "DPR Dance"))
    }

    func testAnEmptyHandleIsNotLinkable() {
        XCTAssertNil(ProfileLink.url(handle: ""))
        XCTAssertNil(ProfileLink.url(handle: "@"))
    }

    // MARK: - A checked address beats a constructed one

    /// The research step checked its URL against the real account. The
    /// constructed one is only a convention, so where both exist the checked
    /// one wins.
    func testAStoredProfileURLIsPreferredOverTheConstructedOne() {
        XCTAssertEqual(
            ProfileLink.url(handle: "jane",
                            storedProfileURL: "https://www.instagram.com/jane.dance/"),
            URL(string: "https://www.instagram.com/jane.dance/"))
    }

    /// Present but unusable is not the same as absent, and neither is a reason
    /// to open something that is not a profile. Falling back to the convention
    /// still names the same account; opening a stored `javascript:` or `file:`
    /// value would not.
    func testAStoredValueThatIsNotAWebAddressFallsBackToTheConstructedOne() {
        for junk in ["", "   ", "not a url", "file:///etc/passwd",
                     "javascript:alert(1)"] {
            XCTAssertEqual(ProfileLink.url(handle: "jane", storedProfileURL: junk),
                           URL(string: "https://www.instagram.com/jane/"),
                           "stored value \(junk) should not have been opened")
        }
    }

    /// And when the handle is not linkable either, a bad stored value produces
    /// no link at all rather than the convention over a value that is nobody.
    func testAnUnusableStoredValueOnASentinelStillProducesNoLink() {
        XCTAssertNil(ProfileLink.url(handle: "unknown", storedProfileURL: "not a url"))
    }

    /// A stored address for a handle the app would refuse is still opened: it
    /// was checked against a real account, which is stronger evidence than the
    /// shape rule the refusal is made of.
    func testAStoredAddressStandsEvenWhereTheHandleWouldBeRefused() {
        XCTAssertEqual(
            ProfileLink.url(handle: "DPR Dance",
                            storedProfileURL: "https://www.instagram.com/dprdance/"),
            URL(string: "https://www.instagram.com/dprdance/"))
    }

    // MARK: - What the control says

    /// Matching the "Edit numbers for <handle>" pattern beside it, and naming
    /// whose profile it opens rather than saying "link".
    func testTheAccessibilityLabelNamesWhoseProfileItOpens() {
        XCTAssertEqual(ProfileLink.accessibilityLabel(handle: "@jane"),
                       "Open jane's profile on Instagram")
    }

    /// A performer can carry a checked profile URL and no handle at all, and a
    /// label built by interpolating the empty name reads as a possessive with
    /// nobody in front of it.
    func testTheLabelStillReadsWhenThereIsNoHandleToName() {
        XCTAssertEqual(ProfileLink.accessibilityLabel(handle: ""),
                       "Open this profile on Instagram")
    }
}
