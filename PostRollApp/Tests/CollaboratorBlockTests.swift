import XCTest

/// #278, done-when 6: the chosen collaborators reach CAPTIONS.txt under their
/// own header, so the upload step is copy and paste.
///
/// CAPTIONS.txt is the deliverable: it is what gets pasted into Instagram. A
/// section that is missing, or that says something the review screen does not,
/// produces a file that reads as complete either way, which is how #221 and
/// #222 were both found.
final class CollaboratorBlockTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func photo(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/postroll-block-test/\(name)")
    }

    private func stats(_ followers: Int, _ likes: Int, _ comments: Int) -> AccountStats {
        AccountStats(followers: followers, likes: likes, comments: comments, recordedOn: now)
    }

    /// A Wednesday tagging seven people, two of them in the first photo, one of
    /// them never counted.
    private func event() -> Event {
        var event = Event(name: "Perpetual Light", org: "DCINY", venue: "Carnegie Hall",
                          date: now, shootType: .fullShow)
        var wed = PostingDay(day: .wednesday)
        let photos = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map(photo)
        wed.photoPaths = photos
        wed.photoTags = [
            photos[0].absoluteString: ["inphoto1", "inphoto2"],
            photos[1].absoluteString: ["strong", "mid1"],
            photos[2].absoluteString: ["mid2", "mid3"],
            photos[3].absoluteString: ["uncounted"],
        ]
        event.days = [DayName.wednesday.rawValue: wed]
        var result = WeekGenerationResult()
        var caption = DayCaption()
        caption.caption = "Carousel day"
        result.wednesday = caption
        event.weekResult = result
        return event
    }

    private var table: [String: AccountStats] {
        [
            "inphoto1": stats(1_000, 10, 1),
            "inphoto2": stats(1_000, 9, 1),
            "strong":   stats(50_000, 5_000, 1_000),
            "mid1":     stats(2_000, 100, 20),
            "mid2":     stats(2_000, 90, 20),
            "mid3":     stats(2_000, 80, 20),
        ]
    }

    private func suggestion() -> CollaboratorPick.Result? {
        CollaboratorPick.suggest(event: event(), day: .wednesday, preset: .balanced,
                                 stats: { table[AccountBook.key($0)] }, asOf: now)
    }

    // MARK: - The block

    func testTheBlockNamesTheFiveToInviteUnderItsOwnHeader() throws {
        let result = try XCTUnwrap(suggestion())
        let block = CollaboratorPick.captionBlock(result)

        XCTAssertTrue(block.hasPrefix(CollaboratorPick.captionHeader), block)
        for candidate in result.suggested {
            XCTAssertTrue(block.contains(candidate.handle), candidate.handle)
        }
    }

    func testTheBlockCarriesTheReasonsNotJustTheNames() throws {
        // An ordered list with no figures is not something anyone can disagree
        // with, and disagreeing is the point: the swap is Dan's call.
        let block = CollaboratorPick.captionBlock(try XCTUnwrap(suggestion()))
        XCTAssertTrue(block.contains("followers"), block)
        XCTAssertTrue(block.contains("engagement"), block)
        XCTAssertTrue(block.lowercased().contains("first photo"), block)
    }

    func testTheBlockNamesTheStrongestAccountTheRuleLeftOut() throws {
        // Without this the exclusion is invisible: an account with ten times
        // anyone's reach would silently never be offered.
        let block = CollaboratorPick.captionBlock(try XCTUnwrap(suggestion()))
        XCTAssertTrue(block.contains("strong"), block)
        XCTAssertTrue(block.lowercased().contains("swap"), block)
    }

    func testTheBlockNamesTheAccountsWithNoNumbersRatherThanDroppingThem() throws {
        // Dropped, they look like accounts that were considered and rejected.
        let block = CollaboratorPick.captionBlock(try XCTUnwrap(suggestion()))
        XCTAssertTrue(block.contains("uncounted"), block)
        XCTAssertTrue(block.lowercased().contains("not counted"), block)
    }

    func testTheBlockNamesInstagramsLimitSoTheNumberFiveIsNotAMystery() throws {
        let block = CollaboratorPick.captionBlock(try XCTUnwrap(suggestion()))
        XCTAssertTrue(block.contains("\(CollaboratorPick.maxPerPost)"), block)
    }

    func testTheBlockCarriesNoBannedDash() throws {
        // The style hook reads source, never runtime output, and these lines
        // are assembled from handles Dan typed.
        let block = CollaboratorPick.captionBlock(try XCTUnwrap(suggestion()))
        XCTAssertFalse(block.contains("\u{2014}"), block)
        XCTAssertFalse(block.contains("\u{2013}"), block)
    }

    // MARK: - In the file

    func testTheExportedCaptionsCarryTheBlock() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collab-block-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let exported = try EventExporter.export(
            event: event(), to: folder, preset: .balanced,
            collaboratorStats: { self.table[AccountBook.key($0)] }, asOf: now)
        let captions = try String(
            contentsOf: exported.folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        XCTAssertTrue(captions.contains(CollaboratorPick.captionHeader), captions)
        // Inside the Wednesday block, not appended to the end of the file where
        // it would read as belonging to the last day.
        let wednesday = try XCTUnwrap(captions.components(separatedBy: "=== ")
            .first(where: { $0.hasPrefix("WEDNESDAY") }))
        XCTAssertTrue(wednesday.contains(CollaboratorPick.captionHeader))
    }

    func testADayUnderTheThresholdGetsNoBlockAtAll() throws {
        // Done-when 7. A header over "no suggestion" is noise on every post
        // that did not need one.
        var event = self.event()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoTags = [wed.photoPaths[0].absoluteString: ["one", "two", "three"]]
        event.days[DayName.wednesday.rawValue] = wed

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collab-none-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let exported = try EventExporter.export(
            event: event, to: folder, preset: .balanced,
            collaboratorStats: { self.table[AccountBook.key($0)] }, asOf: now)
        let captions = try String(
            contentsOf: exported.folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        XCTAssertFalse(captions.contains(CollaboratorPick.captionHeader), captions)
    }

    func testTheExportAndTheScreenNameTheSameFive() throws {
        // Done-when 4: one implementation, not one per surface. The export goes
        // through the same `suggest` the panel does, so a change to the ranking
        // cannot reach one and not the other.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collab-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let exported = try EventExporter.export(
            event: event(), to: folder, preset: .balanced,
            collaboratorStats: { self.table[AccountBook.key($0)] }, asOf: now)
        let captions = try String(
            contentsOf: exported.folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        let onScreen = try XCTUnwrap(suggestion())
        XCTAssertTrue(captions.contains(CollaboratorPick.captionBlock(onScreen)))
    }

    func testAnExportWithNoStatsAtAllStillSaysWhoWasTaggedRatherThanNothing() throws {
        // The realistic first run: nothing has been counted yet. Seven tagged
        // accounts, none rankable. Saying nothing would look like a post that
        // does not need collaborators.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collab-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let exported = try EventExporter.export(
            event: event(), to: folder, preset: .balanced,
            collaboratorStats: { _ in nil }, asOf: now)
        let captions = try String(
            contentsOf: exported.folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        XCTAssertTrue(captions.contains(CollaboratorPick.captionHeader), captions)
        XCTAssertTrue(captions.lowercased().contains("not counted"), captions)
    }

    func testAnUnreadableAccountBookIsSaidInTheFileNotJustOnScreen() throws {
        // Built is not wired. Every account reading as "not counted" is exactly
        // what an unreadable store looks like from here, so the file has to
        // carry which of the two it is, not only the review screen.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collab-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let exported = try EventExporter.export(
            event: event(), to: folder, preset: .balanced,
            collaboratorStats: { _ in nil }, asOf: now,
            collaboratorNotes: [AccountBook.unreadableNote(file: "accounts.json", folder: "~/Library/Application Support/PostRoll")])
        let captions = try String(
            contentsOf: exported.folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        XCTAssertTrue(captions.contains(AccountBook.unreadableNote(file: "accounts.json", folder: "~/Library/Application Support/PostRoll")), captions)
    }
}
