import XCTest

/// #1372: a handle changed is an account changed, so the address checked
/// against the old one cannot stand.
final class CheckedHandleEditTests: XCTestCase {

    private func checked() -> Performer {
        Performer(name: "Jenna", handle: "@jenna",
                  profileURL: "https://www.instagram.com/jenna/")
    }

    func testChangingTheHandleDropsTheAddressCheckedAgainstTheOldOne() {
        var performer = checked()

        performer.setHandle("@someoneelse")

        XCTAssertNil(performer.profileURL,
                     "the row would say this handle was checked against a "
                     + "profile belonging to somebody else")
    }

    func testRetypingTheSameHandleKeepsTheCheck() {
        var performer = checked()

        performer.setHandle("@jenna")

        XCTAssertEqual(performer.profileURL, "https://www.instagram.com/jenna/")
    }

    /// One username, two spellings. Dropping the check on a case change or a
    /// sigil would quietly erase it every time the field is tidied.
    func testCaseAndTheSigilAreNotAChangeOfAccount() {
        var performer = checked()

        performer.setHandle("Jenna")

        XCTAssertEqual(performer.profileURL, "https://www.instagram.com/jenna/")
    }

    func testClearingTheHandleDropsTheCheckToo() {
        var performer = checked()

        performer.setHandle("")

        XCTAssertNil(performer.profileURL)
    }
}
