import XCTest

// MARK: - The same rule for a generated report (#439)

final class UnsavedReportNoticeTests: XCTestCase {

    func testASavedReportSaysNothing() {
        XCTAssertNil(InsightsDisplay.unsavedReportNotice(save: .saved),
                     "a report that was written needs no caveat")
    }

    func testARefusedReportSaysItWasNotKept() {
        let text = InsightsDisplay.unsavedReportNotice(save: .blocked)

        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("not saved") == true, text ?? "")
        XCTAssertTrue(text?.contains("gone when you quit") == true, text ?? "")
    }

    func testAFailedReportNamesTheReasonCleanly() {
        let text = InsightsDisplay.unsavedReportNotice(save: .failed("The disk is full."))

        XCTAssertNotNil(text)
        XCTAssertFalse(text?.contains("..") == true, text ?? "")
        XCTAssertTrue(text?.contains("disk is full") == true, text ?? "")
    }
}
