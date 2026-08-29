import XCTest

/// #289: a stale figure on an account that keeps coming back.
///
/// A remembered follower or engagement figure goes stale after six months, but
/// that flag is only ever seen on the collaborator panel for a day that has
/// been expanded. An account tagged every month can go stale in March and
/// nothing says so until Dan happens to scroll to a post that tags them, by
/// which point the ranking has been quietly running on an old number.
///
/// Dan, 2026-08-10: "a lot of the time I tag people once and never again."
/// Measured across his 19 real events on the same day: 38 accounts ever tagged,
/// 32 of them on exactly one event. Chasing all 38 is wasted effort. The 6 that
/// recur are the ones whose numbers are both wrong and load-bearing, and every
/// one of them is a venue or org handle: @carnegiehall on 6 events, then
/// @dciny, @everyvoicechoirs, @decodamusic, @lincolncenter and @greenwich_house
/// on 2 each.
final class RecurringAccountsTests: XCTestCase {

    // MARK: - Building events

    private func event(_ name: String,
                       eventHandles: String = "",
                       dayHandles: [String] = [],
                       photoTags: [String] = []) -> Event {
        var e = Event(name: name, org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        e.eventHandles = eventHandles
        var posting = PostingDay(day: .wednesday)
        posting.tagHandles = dayHandles
        if !photoTags.isEmpty {
            let photo = URL(fileURLWithPath: "/p/\(name).jpg")
            posting.photoPaths = [photo]
            posting.photoTags = [photo.absoluteString: photoTags]
        }
        e.days[DayName.wednesday.rawValue] = posting
        return e
    }

    /// A pinned clock, so an age asserted in days is the age the test meant
    /// rather than one that rounds differently depending on when it runs.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func counted(_ days: Int, followers: Int = 1000) -> AccountStats {
        AccountStats(followers: followers, likes: 50, comments: 5,
                     recordedOn: now.addingTimeInterval(-Double(days) * 86_400))
    }

    // MARK: - Every account a post actually tags

    func testTheAccountsTaggedIncludeTheOrgAndVenueHandles() {
        // They are applied to every post, and the app says so on the tagging
        // screen. Leaving them out of the book meant the accounts Dan tags most
        // often were the only ones it could never remember, which is exactly
        // backwards: those are the ones a ranking leans on hardest.
        let e = event("a", eventHandles: "carnegiehall, dciny", dayHandles: ["@performer"])

        XCTAssertEqual(Set(CaptionBlocks.accountsTagged(event: e)),
                       ["carnegiehall", "dciny", "performer"])
    }

    func testTheAccountsTaggedDeduplicateAcrossBothSources() {
        // A venue handle also typed as a day tag is one account, not two. The
        // spelling that survives is the day tag's, because the display form is
        // deliberately kept (#279); what must not survive is a second record.
        let e = event("a", eventHandles: "carnegiehall", dayHandles: ["@CarnegieHall"])

        XCTAssertEqual(CaptionBlocks.accountsTagged(event: e).count, 1)
        XCTAssertEqual(CaptionBlocks.accountsTagged(event: e).map { $0.lowercased() },
                       ["carnegiehall"])
    }

    // MARK: - The field as it is actually written

    func testTheCommaSeparatedFormEveryRealEventUsesIsRead() {
        // Verbatim from the events on disk. The field was only ever parsed for
        // @ handles inside prose, and every real event writes bare names, so
        // nothing was extracted from any of them.
        XCTAssertEqual(EventHandleSuggestions.accounts(in: "dciny, carnegiehall"),
                       ["dciny", "carnegiehall"])
        XCTAssertEqual(EventHandleSuggestions.accounts(in: "carnegiehall"), ["carnegiehall"])
        XCTAssertEqual(
            EventHandleSuggestions.accounts(in: "thebayridgeschoolofmusic, carnegiehall"),
            ["thebayridgeschoolofmusic", "carnegiehall"])
    }

    func testASentenceWithHandlesInItStillReadsAsHandles() {
        XCTAssertEqual(
            EventHandleSuggestions.accounts(in: "@bludlineodyssey presented by @matchbookfestival"),
            ["@bludlineodyssey", "@matchbookfestival"])
    }

    func testProseWithNoHandleInItBecomesNoAccount() {
        // The reason a bare piece has to be a single word: otherwise a
        // description of the event turns into an account nobody can tag.
        XCTAssertEqual(EventHandleSuggestions.accounts(in: "presented by the festival"), [])
        XCTAssertEqual(EventHandleSuggestions.accounts(in: "Carnegie Hall, New York"), [])
    }

    func testAnEmptyFieldYieldsNothing() {
        XCTAssertEqual(EventHandleSuggestions.accounts(in: ""), [])
        XCTAssertEqual(EventHandleSuggestions.accounts(in: " ,  , "), [])
    }

    func testTheCaptionsOwnTagListIsUnchanged() {
        // The org and venue handles reach every post by their own route. Adding
        // them here would print them twice and eat slots from the cap that
        // decides who gets tagged at all (#281).
        let e = event("a", eventHandles: "carnegiehall", dayHandles: ["@performer"])

        XCTAssertEqual(CaptionBlocks.weekTagList(event: e), ["performer"])
    }

    func testAnEventWithNoHandlesAtAllTagsNobody() {
        XCTAssertEqual(CaptionBlocks.accountsTagged(event: event("a")), [])
    }

    // MARK: - Which accounts recur

    func testAnAccountOnOneEventDoesNotRecur() {
        // 32 of Dan's 38. Asking for numbers on these is the wasted effort the
        // whole issue exists to avoid.
        let events = [event("a", dayHandles: ["@once"]),
                      event("b", dayHandles: ["@other"])]

        XCTAssertEqual(RecurringAccounts.eventCounts(events: events)["once"], 1)
    }

    func testAnAccountOnTwoEventsRecurs() {
        let events = [event("a", eventHandles: "carnegiehall"),
                      event("b", eventHandles: "carnegiehall")]

        XCTAssertEqual(RecurringAccounts.eventCounts(events: events)["carnegiehall"], 2)
    }

    func testAnAccountTaggedTwiceWithinOneEventStillCountsOnce() {
        // Recurrence is about coming back, not about how many slots one week
        // used. Counting tags rather than events would make a single heavily
        // tagged week look like a returning relationship.
        let e = event("a", eventHandles: "carnegiehall",
                      dayHandles: ["@carnegiehall"], photoTags: ["@CARNEGIEHALL"])

        XCTAssertEqual(RecurringAccounts.eventCounts(events: [e])["carnegiehall"], 1)
    }

    // MARK: - What needs attention

    func testARecurringAccountWithNoNumbersIsSurfaced() {
        // @carnegiehall today: six events, no figures at all. The ranking
        // cannot score it, and it is the single most load-bearing account on
        // the list.
        let events = [event("a", eventHandles: "carnegiehall"),
                      event("b", eventHandles: "carnegiehall")]

        let items = RecurringAccounts.needingAttention(
            events: events, stats: { _ in nil }, asOf: Date())

        XCTAssertEqual(items.map(\.handle), ["carnegiehall"])
        XCTAssertEqual(items.first?.eventCount, 2)
        XCTAssertEqual(items.first?.need, .neverCounted)
    }

    func testARecurringAccountWithStaleNumbersIsSurfaced() {
        let events = [event("a", eventHandles: "dciny"), event("b", eventHandles: "dciny")]

        let items = RecurringAccounts.needingAttention(
            events: events, stats: { _ in self.counted(400) }, asOf: self.now)

        XCTAssertEqual(items.map(\.handle), ["dciny"])
        guard case .stale(let daysOld)? = items.first?.need else {
            return XCTFail("a 400 day old figure is stale")
        }
        XCTAssertEqual(daysOld, 400)
    }

    func testARecurringAccountWithFreshNumbersIsNotSurfaced() {
        let events = [event("a", eventHandles: "dciny"), event("b", eventHandles: "dciny")]

        XCTAssertEqual(RecurringAccounts.needingAttention(
            events: events, stats: { _ in self.counted(10) }, asOf: self.now), [])
    }

    func testAOneOffWithNoNumbersIsNotSurfaced() {
        // The constraint that shapes the whole feature. Surfacing these would
        // bury the six that matter under thirty two that do not.
        let events = [event("a", dayHandles: ["@once"])]

        XCTAssertEqual(RecurringAccounts.needingAttention(
            events: events, stats: { _ in nil }, asOf: Date()), [])
    }

    func testAOneOffWithStaleNumbersIsNotSurfacedEither() {
        let events = [event("a", dayHandles: ["@once"])]

        XCTAssertEqual(RecurringAccounts.needingAttention(
            events: events, stats: { _ in self.counted(400) }, asOf: self.now), [])
    }

    func testTheMostLoadBearingAccountComesFirst() {
        // Ordered by how often it comes back, because that is what makes a
        // wrong number expensive.
        let events = [event("a", eventHandles: "carnegiehall, dciny"),
                      event("b", eventHandles: "carnegiehall, dciny"),
                      event("c", eventHandles: "carnegiehall")]

        let items = RecurringAccounts.needingAttention(
            events: events, stats: { _ in nil }, asOf: Date())

        XCTAssertEqual(items.map(\.handle), ["carnegiehall", "dciny"])
        XCTAssertEqual(items.map(\.eventCount), [3, 2])
    }

    func testNoEventsMeansNothingToSay() {
        XCTAssertEqual(RecurringAccounts.needingAttention(
            events: [], stats: { _ in nil }, asOf: Date()), [])
    }

    // MARK: - What Dan is told

    func testTheSummaryNamesHowManyNeedNumbers() throws {
        let events = [event("a", eventHandles: "carnegiehall"),
                      event("b", eventHandles: "carnegiehall")]
        let items = RecurringAccounts.needingAttention(
            events: events, stats: { _ in nil }, asOf: Date())

        let summary = try XCTUnwrap(RecurringAccounts.summary(items))
        XCTAssertTrue(summary.contains("carnegiehall"), summary)
    }

    func testTheSummaryKeepsTheTwoCausesApart() throws {
        // Never counted and counted long ago are different jobs: one is typing
        // a number in for the first time, the other is checking one that has
        // drifted. A single lumped count tells Dan neither (L11).
        let never = RecurringAccounts.Attention(
            handle: "carnegiehall", eventCount: 6, need: .neverCounted)
        let stale = RecurringAccounts.Attention(
            handle: "dciny", eventCount: 2, need: .stale(daysOld: 400))

        let both = try XCTUnwrap(RecurringAccounts.summary([never, stale]))
        let onlyNever = try XCTUnwrap(RecurringAccounts.summary([never]))

        XCTAssertNotEqual(both, onlyNever)
        XCTAssertTrue(both.contains("carnegiehall"), both)
        XCTAssertTrue(both.contains("dciny"), both)
    }

    func testTheSummaryDoesNotSendDanSomewhereTheseAccountsAreNot() throws {
        // The collaborator list is built from day and per-photo tags only, so a
        // venue or org handle can never appear in it, and those are exactly the
        // accounts this names. Telling him to go there names a target and gives
        // him nowhere to go (L80). The way in is a control on this banner.
        let items = [RecurringAccounts.Attention(
            handle: "carnegiehall", eventCount: 6, need: .neverCounted)]

        let summary = try XCTUnwrap(RecurringAccounts.summary(items))

        XCTAssertFalse(summary.lowercased().contains("collaborator"), summary)
    }

    func testEveryNamedAccountCanBeActedOn() {
        // Whatever the banner says, each account it names has to be reachable
        // from it. Capped at the number of names the message itself carries, so
        // it cannot promise a control for an account it did not name.
        let items = (1...6).map {
            RecurringAccounts.Attention(handle: "account\($0)", eventCount: 2, need: .neverCounted)
        }

        let actionable = RecurringAccounts.actionable(items)

        XCTAssertEqual(actionable.count, 3)
        XCTAssertEqual(actionable.map(\.handle), ["account1", "account2", "account3"])
    }

    func testThereIsNoSummaryWhenNothingNeedsAttention() {
        XCTAssertNil(RecurringAccounts.summary([]))
    }

    // MARK: - How loudly the panel asks

    func testTheNumbersControlIsProminentForAnAccountThatKeepsComingBack() {
        let counts = ["carnegiehall": 6, "once": 1]

        XCTAssertEqual(RecurringAccounts.emphasis(handle: "@CarnegieHall", in: counts),
                       .prominent)
    }

    func testTheNumbersControlIsQuietForAOneOff() {
        // It stays reachable. Nothing here is impossible, and a control removed
        // because it is usually not worth it only ever stops the person who
        // meant to use it (L54). It just stops competing for attention.
        let counts = ["carnegiehall": 6, "once": 1]

        XCTAssertEqual(RecurringAccounts.emphasis(handle: "@once", in: counts), .quiet)
        XCTAssertEqual(RecurringAccounts.emphasis(handle: "@neverseen", in: counts), .quiet)
    }

    func testARecurringAccountSaysHowOftenItComesBack() {
        // The reason this one is worth a minute, said where the minute is spent,
        // rather than leaving Dan to work out why one row looks louder.
        let note = RecurringAccounts.recurrenceNote(handle: "@carnegiehall",
                                                    in: ["carnegiehall": 6])

        XCTAssertEqual(note, "Tagged on 6 events")
    }

    func testAOneOffHasNothingToSayAboutRecurrence() {
        XCTAssertNil(RecurringAccounts.recurrenceNote(handle: "@once", in: ["once": 1]))
    }

    // MARK: - The way in actually exists on the screen

    private func exportViewSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/ExportView.swift"),
            encoding: .utf8)
    }

    /// A SwiftUI screen with this much environment cannot be built in a test, so
    /// what is guarded is that the wiring is present: the banner offers a control
    /// per named account, that control opens the numbers form, and saving
    /// re-reads the answer. Without the last one the account just counted keeps
    /// asking to be counted.
    func testTheBannerOffersAControlForEachAccountItNames() throws {
        let source = try exportViewSource()

        XCTAssertTrue(source.contains("RecurringAccounts.actionable("),
                      "the banner names accounts with no control to act on them, "
                      + "and the collaborator list cannot show these accounts, so "
                      + "there would be nowhere to go")
        XCTAssertTrue(source.contains("editingRecurringAccount = item"),
                      "the control does not open anything")
    }

    func testTheControlOpensTheSameNumbersForm() throws {
        let source = try exportViewSource()

        XCTAssertTrue(source.contains(".sheet(item: $editingRecurringAccount)"),
                      "nothing presents the form the control claims to open")
        XCTAssertTrue(source.contains("AccountNumbersSheet("),
                      "a second numbers form here would drift from the one the "
                      + "collaborator panel uses")
    }

    func testSavingRecordsTheNumbersAndStopsTheBannerAsking() throws {
        let source = try exportViewSource()

        // Scoped to the save handler, not the whole file. The refresh call also
        // appears in onAppear and onChange, so a whole-file search passes even
        // with the save path's copy deleted: the first version of this test did
        // exactly that, and only broke the code to find out.
        let handler = try XCTUnwrap(
            source.range(of: ".sheet(item: $editingRecurringAccount)").map { start in
                let rest = source[start.upperBound...]
                return String(rest[..<(rest.range(of: "onCancel:")?.lowerBound ?? rest.endIndex)])
            })

        // Through the screen's injected book since #937, not the shared one.
        // The rule is unchanged: this handler has to RECORD, or the banner asks
        // about the same account for ever.
        XCTAssertTrue(handler.contains("accounts.record(handle: target.handle"),
                      "the form saves nothing, so the banner would ask forever")
        XCTAssertTrue(handler.contains("refreshRecurringAccounts()"),
                      "the banner is a claim about the book and is not re-read "
                      + "when the book changes, so the account just counted keeps "
                      + "asking to be counted")
    }

    func testTheBannerIsNotRecomputedOnEveryRedraw() throws {
        // It walks every event's tag list, so it belongs in stored state rather
        // than in the view body, which runs on every redraw (L91).
        let source = try exportViewSource()

        XCTAssertTrue(source.contains("@State private var recurringAccounts"))
        XCTAssertFalse(source.contains("if RecurringAccounts.needingAttention("),
                       "the whole event list is being walked to decide whether "
                       + "to draw the banner")
    }

    // MARK: - The book is told about every account a post tags

    func testTheExportRemembersEveryAccountItTags() throws {
        // The book's own promise is that it holds everyone ever tagged. It is
        // fed at export, and feeding it a narrower list than the post actually
        // tags is how the venue and org handles stayed invisible to it.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Services/ExportManager.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("CaptionBlocks.accountsTagged(event:"),
                      "the export is still telling the book a narrower list than "
                      + "the post tags, so the accounts tagged on every post are "
                      + "the only ones it can never remember")
    }
}
