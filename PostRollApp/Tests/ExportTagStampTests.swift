import XCTest

/// #483: the account book records tags that actually shipped.
///
/// It was written at the START of the export, before the text export or any
/// asset copy ran, and a failed export never rolled it back, so it recorded a
/// week of tags as sent when nothing had reached disk. The freshness stats that
/// decide which accounts are worth chasing were then reading from a non-event.
///
/// The book here is built on a scratch file, never `AccountBook.shared`: a test
/// that wrote the real book would edit Dan's actual account history (L2).
@MainActor
final class ExportTagStampTests: XCTestCase {

    private var file: URL!
    private var book: AccountBook!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("accounts-\(UUID().uuidString).json")
        book = AccountBook(fileURL: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private let runStartedAt = Date(timeIntervalSince1970: 1_760_000_000)

    private var stamp: ExportTagStamp {
        ExportTagStamp(handles: ["@carnegiehall", "@dcinyconcerts"], at: runStartedAt)
    }

    /// A run that never reached the success path never applies its stamp, and
    /// this is what that looks like from the book's side.
    func testAStampThatIsNeverAppliedLeavesTheBookAlone() {
        _ = stamp

        XCTAssertNil(book.record(for: "@carnegiehall"),
                     "the book knows about an account no finished export ever tagged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the book was written to disk by an export that never committed")
    }

    func testApplyingItRecordsEveryHandle() {
        stamp.apply(to: book)

        XCTAssertEqual(book.record(for: "@carnegiehall")?.lastTaggedOn, runStartedAt)
        XCTAssertEqual(book.record(for: "@dcinyconcerts")?.lastTaggedOn, runStartedAt)
    }

    /// Stamped with when the run STARTED, not with when the bookkeeping ran.
    /// The record is about the export, and the two can be minutes apart on a
    /// week that renders reels.
    func testItRecordsWhenTheRunStartedRatherThanWhenItFinished() {
        stamp.apply(to: book)

        XCTAssertEqual(book.record(for: "@carnegiehall")?.lastTaggedOn, runStartedAt)
    }

    func testAWeekThatTagsNobodyWritesNothingAtAll() {
        ExportTagStamp(handles: [], at: runStartedAt).apply(to: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "an export tagging nobody still wrote the book")
    }

    func testAnEmptyStampKnowsItIsEmpty() {
        XCTAssertTrue(ExportTagStamp(handles: [], at: runStartedAt).isEmpty)
        XCTAssertFalse(stamp.isEmpty)
    }

    /// Applying it twice, which a retried export would do, must not invent a
    /// second history for the same account.
    func testApplyingItTwiceIsTheSameAsApplyingItOnce() {
        stamp.apply(to: book)
        stamp.apply(to: book)

        XCTAssertEqual(book.all.filter { $0.handle.lowercased().contains("carnegiehall") }.count, 1)
    }
}
