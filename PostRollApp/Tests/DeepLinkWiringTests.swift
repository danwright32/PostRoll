import XCTest

/// The link handling is actually connected to the app (#840).
///
/// Every value type under this feature can be perfect while nothing on screen
/// calls any of it: built is not wired (L3). There is no way to fire a real
/// `postroll://` URL from a unit test bundle, so these read the sources that
/// have to do the connecting, with comments stripped so prose describing a
/// connection cannot satisfy a check for one (L103).
final class DeepLinkWiringTests: XCTestCase {

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func source(_ relativePath: String) throws -> String {
        try source(at: sourcesDirectory.appendingPathComponent(relativePath))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every Swift file under `Sources`, so a sweep cannot be answered by the
    /// one file somebody remembered to list (L96).
    ///
    /// Through `RepoFixture.files` rather than by trimming the root off each
    /// absolute path (#941). The trim is a substitution, so it removed a match
    /// from the MIDDLE whenever `#filePath` and the enumerator disagreed about
    /// symlinks, which they do for any checkout under `/tmp`: this suite failed
    /// from a worktree with "privateAppState.swift", two names fused into one.
    /// Reading the file through the url the walk handed back also means the
    /// path is never rebuilt from a string a second time.
    private func everySource() throws -> [(path: String, code: String)] {
        var found: [(String, String)] = []
        for entry in RepoFixture.files(under: sourcesDirectory, withExtension: "swift") {
            found.append((entry.relativePath, try source(at: entry.url)))
        }
        XCTAssertGreaterThan(found.count, 100,
                             "the sweep found \(found.count) files, so it is not reading Sources at all")
        return found
    }

    // MARK: - The URL reaches the app

    func testTheAppInstallsTheDelegateThatReceivesLinks() throws {
        // Without this, `application(_:open:)` is never called and the scheme
        // is declared by a bundle that does nothing with it.
        let code = try source("PostRollApp.swift")

        XCTAssertTrue(code.contains("NSApplicationDelegateAdaptor(DeepLinkDelegate.self)"),
                      "no delegate is installed, so a postroll:// link reaches nothing: \(code)")
    }

    func testTheWindowDrainsWhatArrivedBeforeItExisted() throws {
        // The cold launch: the URL is delivered, then the scene is built. A
        // window that only listened for CHANGES would sit there with the link
        // already waiting in the inbox and never look.
        let code = try source("Views/MainWindowView.swift")

        XCTAssertTrue(code.contains("onAppear"),
                      "the window never drains the inbox on appear: \(code)")
        XCTAssertTrue(code.contains("handleWaitingDeepLinks"),
                      "the window never drains the inbox at all: \(code)")
    }

    func testTheWindowAlsoNoticesALinkArrivingWhileItIsOpen() throws {
        // The warm case. `onAppear` alone fires once, so a click while PostRoll
        // is already running would do nothing until the window was rebuilt.
        let code = try source("Views/MainWindowView.swift")
        let flattened = code.split(whereSeparator: { $0 == "\n" || $0 == " " }).joined(separator: " ")

        XCTAssertNotNil(flattened.range(of: #"onChange\(of: \w+\.pending\)"#,
                                        options: .regularExpression),
                        "nothing in MainWindowView watches the inbox's pending list, so a "
                        + "link clicked while the window is open waits for a relaunch")
    }

    // MARK: - The draft reaches the form

    func testTheSheetIsGivenThePrefill() throws {
        let code = try source("Views/MainWindowView.swift")

        XCTAssertTrue(code.contains("NewEventSheet(prefill: appState.newEventPrefill)"),
                      "the sheet is presented without the link's values: \(code)")
    }

    func testEveryFieldTheLinkCarriesReachesTheForm() throws {
        // The list of fields is taken from the draft itself rather than written
        // out here, so a field added to the link is covered by this without
        // anybody remembering to extend it (L41, L96).
        let draft = DeepLink.EventDraft(name: "", org: "", venue: "", venueContext: "",
                                        date: Date(timeIntervalSince1970: 0), bookingID: UUID())
        let fields = Mirror(reflecting: draft).children.compactMap(\.label)
        XCTAssertEqual(fields.count, 6, "the draft's shape changed: \(fields)")

        let code = try source("Views/NewEventSheet.swift")
        for field in fields {
            XCTAssertTrue(code.contains("prefill?.\(field)"),
                          "the link carries \(field) and the sheet never reads it, so that "
                          + "value is silently dropped between the two")
        }
    }

    func testTheSheetBuildsItsEventThroughTheOnePlaceThatDoes() throws {
        let code = try source("Views/NewEventSheet.swift")

        XCTAssertTrue(code.contains("NewEventForm.event("),
                      "the sheet builds an Event of its own, so the folding rule and the "
                      + "booking id now have two spellings: \(code)")
    }

    // MARK: - The prefill cannot outlive the click

    func testNothingOpensTheSheetBehindPresentNewEvent() throws {
        // `presentNewEvent` is what clears the prefill. A call site that flips
        // the flag directly opens the next hand-typed event on the last link's
        // values, and nothing on screen would say where they came from.
        let offenders = try everySource()
            .filter { $0.path != "AppState.swift" }
            .filter { $0.code.contains("showingNewEvent = true") }
            .map(\.path)

        XCTAssertEqual(offenders, [],
                       "these open the New Event sheet without going through "
                       + "presentNewEvent, so a stale prefill survives: \(offenders)")
    }

    // MARK: - A click that opened no sheet still says something

    func testTheWindowShowsWhatALinkDidWhenItOpenedNoSheet() throws {
        let code = try source("Views/MainWindowView.swift")

        XCTAssertTrue(code.contains("appState.deepLinkNotice"),
                      "a link that was refused, or that pointed at an event already made, "
                      + "changes nothing on screen and says nothing: \(code)")
        XCTAssertTrue(code.contains("appState.dismissDeepLinkNotice()"),
                      "the notice has no way to be waved away, so it stays until relaunch: \(code)")
    }

    // MARK: - There is one window, so there is one sheet

    func testTheAppDeclaresASingleWindowRatherThanAGroup() throws {
        // Measured on the real machine after #840 shipped: the window count
        // went 1, then 2 after one link, then 3 after a quit and another link
        // (#842). SwiftUI's `WindowGroup` treats an incoming URL open event as
        // an external event and opens a NEW window for it, and window
        // restoration brings the extras back after a quit.
        //
        // That is not merely untidy. `showingNewEvent` is one flag on the
        // shared AppState and every window binds a sheet to it, so one link put
        // up a New Event sheet on each of them, all with the same prefill, and
        // cancelling one left the others standing.
        //
        // `Window` is a scene with exactly one window, which is what PostRoll
        // has always been: the New Window command is already replaced in
        // `.commands`. Declaring it removes the whole class rather than the one
        // route into it.
        let code = try source("PostRollApp.swift")

        XCTAssertTrue(code.contains("Window("),
                      "the app declares no single Window scene: \(code)")
        XCTAssertFalse(code.contains("WindowGroup"),
                       "the app is back to a WindowGroup, which SwiftUI multiplies on every "
                       + "incoming URL, so each link leaves a window behind and puts up "
                       + "another copy of the same sheet (#842)")
    }

    // MARK: - A sheet nobody asked for does not commit on the next keystroke

    func testCreateIsNotTheDefaultActionOnASheetALinkRaised() throws {
        // #844: an event reached the real store from a link with nobody
        // deliberately pressing Create. A hands off probe then showed the code
        // does not commit on its own (twenty seconds, sheet up, store
        // unchanged), which leaves a keystroke as what did it.
        //
        // The hazard is the combination, not either half. A link raises this
        // sheet and brings PostRoll to the front at a moment the person did not
        // choose, which on a cold launch is seconds after they clicked and
        // moved on to something else. `defaultAction` then puts a committing
        // button under the next Return they type, and what it commits is an
        // event whose whole point is that it was reviewed first.
        //
        // Kept for a sheet opened BY HAND, where Return is the affordance
        // somebody just asked for.
        let code = try source("Views/NewEventSheet.swift")
        let flattened = code.split(whereSeparator: { $0 == "\n" || $0 == " " }).joined(separator: " ")

        XCTAssertFalse(flattened.contains("keyboardShortcut(.defaultAction)"),
                       "Create is the unconditional default action again, so a link that "
                       + "raises this sheet puts it under whatever the person types next (#844)")
        XCTAssertNotNil(flattened.range(of: #"keyboardShortcut\([^)]*prefill[^)]*\)"#,
                                        options: .regularExpression),
                        "Create's shortcut no longer depends on whether a link filled the "
                        + "form in, so the two cases cannot differ: \(flattened)")
    }

    func testTheWindowSaysWhenTheWrongCopyAnsweredTheLink() throws {
        // Four PostRoll.app bundles exist on this Mac and macOS picks which one
        // answers. `AnsweringCopy` can be perfect and still say nothing to
        // anybody if the window never renders it.
        let code = try source("Views/MainWindowView.swift")

        XCTAssertTrue(code.contains("appState.answeringCopyNotice"),
                      "a link answered by a Debug build creates its event in a store Dan "
                      + "never opens, and the window says nothing")
        XCTAssertTrue(code.contains("appState.dismissAnsweringCopyNotice()"),
                      "the copy warning has no way to be waved away")
    }
}
