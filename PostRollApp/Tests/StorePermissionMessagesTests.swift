import XCTest

/// #563: a refusal and a damaged file must not say the same thing.
///
/// `isPermissionDenied` landed with `isFileNotFound` in #557, and only the OCR
/// rescan used it. The three stores holding Dan's actual data still collapsed
/// everything that is not "absent" into one unreadable message, so a
/// permissions refusal on PostRoll's own storage read in exactly the same words
/// as a corrupt file or an I/O error.
///
/// That is the vaguest message on the most important data, and the two need
/// different things from him: a refusal is a permissions problem on a file that
/// is still intact, while a corrupt or unreadable file is a
/// restore-from-backup situation. Distinct causes get distinct messages, and a
/// message may claim only what its check actually measured (L11).
///
/// The other half of this is what the message must NOT do (L104): a branch
/// written for refusals that also catches I/O errors would replace the honest
/// "could not be read" with a permissions story nothing measured, so every case
/// here is asserted against its neighbour rather than alone.
final class StorePermissionMessagesTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store_denied_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Every file here is left unreadable on purpose, so access has to come
        // back before the tree can be removed.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func skipIfRoot() throws {
        try XCTSkipIf(getuid() == 0, "permission bits mean nothing to root")
    }

    /// A file that exists, holds real bytes, and this process may not read.
    private func refusedFile(named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("[]".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: url.path)
        return url
    }

    private var refusal: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    }

    private struct DiskFault: LocalizedError {
        var errorDescription: String? { "The volume could not be found." }
    }

    // MARK: - The shared wording

    func testARefusalIsNotWordedAsAFileThatCouldNotBeRead() {
        let refused = StoreRecoveryText.unreadable("Your saved events", refusal)
        let broken = StoreRecoveryText.unreadable("Your saved events", DiskFault())

        XCTAssertNotEqual(refused, broken,
                          "a refusal and an I/O error are telling Dan the same thing")
        XCTAssertTrue(refused.lowercased().contains("permission"),
                      "the refusal does not name itself as one: \(refused)")
        XCTAssertTrue(refused.lowercased().contains("refused"),
                      "the refusal does not say what happened: \(refused)")
    }

    /// The half that is easy to break: a branch written for refusals must not
    /// swallow the errors it was not measured for.
    func testAnOrdinaryFailureKeepsSayingItCouldNotBeRead() {
        let broken = StoreRecoveryText.unreadable("Your saved events", DiskFault())

        XCTAssertTrue(broken.contains("could not be read"),
                      "an I/O error stopped saying so: \(broken)")
        XCTAssertTrue(broken.contains("The volume could not be found."),
                      "the measured reason was dropped: \(broken)")
        XCTAssertFalse(broken.lowercased().contains("permission"),
                       "an I/O error is being reported as a permissions problem: \(broken)")
    }

    func testAMissingFileIsStillNotARefusal() {
        let absent = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let message = StoreRecoveryText.unreadable("Your saved events", absent)

        XCTAssertFalse(message.lowercased().contains("permission"),
                       "an absent file is being reported as a refusal: \(message)")
    }

    /// The promise the save gate makes has to survive the new branch, or the
    /// refusal message says nothing about the writing having stopped.
    func testARefusalStillSaysNothingMoreWillBeSaved() {
        let refused = StoreRecoveryText.unreadable("Your saved events", refusal)

        XCTAssertTrue(refused.contains("nothing new will be saved"),
                      "the refusal does not say saving has stopped: \(refused)")
        XCTAssertTrue(refused.contains("Nothing was changed"),
                      "the refusal does not say the file is intact: \(refused)")
    }

    /// What #557 learned, kept: this data lives under Application Support,
    /// which System Settings does not list under Privacy & Security > Files and
    /// Folders. A remedy has to name a step that can change the state it is
    /// offered for (L111), and sending Dan to a pane with no switch on it is
    /// worse than naming no remedy at all.
    func testTheRefusalNamesNoSettingsPaneThatCannotHelp() {
        let refused = StoreRecoveryText.unreadable("Your saved events", refusal).lowercased()

        for misdirection in ["system settings", "privacy", "files and folders",
                             "full disk access", "system preferences"] {
            XCTAssertFalse(refused.contains(misdirection),
                           "the refusal sends Dan to \(misdirection), which cannot help")
        }
    }

    func testTheSubjectIsStillNamed() {
        XCTAssertTrue(
            StoreRecoveryText.unreadable("Your imported Instagram history", refusal)
                .contains("Your imported Instagram history"),
            "a refusal that does not say which store it is about identifies nothing")
    }

    // MARK: - The three stores that hold Dan's data

    func testEventStoreNamesARefusal() throws {
        try skipIfRoot()
        let store = try refusedFile(named: "events.json")

        let result = EventStore.load(from: store)

        XCTAssertEqual(result.status, .unreadable)
        let message = try XCTUnwrap(result.recoveryMessage)
        XCTAssertTrue(message.lowercased().contains("refused"),
                      "a refused events file reads as a generic failure: \(message)")
    }

    @MainActor
    func testAnalyticsStoreNamesARefusal() throws {
        try skipIfRoot()
        let file = try refusedFile(named: "analytics.json")

        let store = AnalyticsStore(fileURL: file)

        let message = try XCTUnwrap(store.recoveryMessage)
        XCTAssertTrue(message.lowercased().contains("refused"),
                      "a refused analytics file reads as a generic failure: \(message)")
    }

    @MainActor
    func testAccountBookNamesARefusal() throws {
        try skipIfRoot()
        let file = try refusedFile(named: "accounts.json")

        let book = AccountBook(fileURL: file)

        let note = try XCTUnwrap(book.recoveryNote)
        XCTAssertTrue(note.lowercased().contains("refused"),
                      "a refused account book reads as a generic failure: \(note)")
        XCTAssertNotEqual(
            note,
            AccountBook.unreadableNote(file: "accounts.json", folder: dir.path),
            "the refusal is worded identically to an unreadable file")
    }

    /// The account book's own two states, told apart without a disk: a refusal
    /// says the numbers are intact and behind a permissions problem, while an
    /// unreadable file says only that it could not be read.
    @MainActor
    func testTheAccountBookRefusalDoesNotClaimTheNumbersAreDamaged() {
        let refused = AccountBook.refusedNote(file: "accounts.json", folder: "~/Library")

        XCTAssertTrue(refused.contains("accounts.json"),
                      "a note that does not name the file identifies nothing in Finder")
        XCTAssertTrue(refused.contains("~/Library"),
                      "a note that does not name the folder identifies nothing in Finder")
        XCTAssertTrue(refused.lowercased().contains("permission"),
                      "the refusal does not name itself as one: \(refused)")
        XCTAssertFalse(refused.lowercased().contains("not account data"),
                       "a refused file is being described as damaged: \(refused)")
    }

    /// A file the process may read but which holds the wrong bytes must keep
    /// its own wording, or the corrupt path inherits a permissions story
    /// nothing measured.
    @MainActor
    func testAReadableFileHoldingTheWrongBytesIsNotARefusal() throws {
        let file = dir.appendingPathComponent("accounts.json")
        try Data("not account data at all".utf8).write(to: file)

        let book = AccountBook(fileURL: file)

        let note = try XCTUnwrap(book.recoveryNote)
        XCTAssertFalse(note.lowercased().contains("refused"),
                       "corrupt bytes are being reported as a refusal: \(note)")
    }
}
