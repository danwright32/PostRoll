import XCTest

/// Every menu command that raises a sheet opens the window first (#884, #847).
///
/// `presentNewEvent` and `presentOutdatedDesigns` only set state, and a sheet
/// with no window has nowhere to be presented. Nothing in this app opened a
/// window from code until #884, so with the window closed Cmd+N recorded a
/// request and NOTHING appeared, and the form then turned up later on whatever
/// window opened next.
///
/// A source guard, deliberately, and the second of two. The real one is
/// `WindowLifecycleUITests`, which closes the window and presses the command
/// against the running app; this exists because a THIRD command added to the
/// same group is the way the defect comes back, and it comes back silently. A
/// text match cannot see behaviour, but it can see a `Button` whose action
/// never asks for a window (L30: fix the class, not the instance).
final class SheetCommandsOpenTheWindowTests: XCTestCase {

    private func source() throws -> String {
        let file = RepoFixture.repoRoot()
            .appendingPathComponent("PostRollApp/Sources/PostRollApp.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The body of the commands type, which is where the menu is declared.
    private func commandsBody() throws -> String {
        let text = try source()
        guard let start = text.range(of: "private struct SheetCommands: Commands {"),
              let end = text.range(of: "@main", range: start.upperBound..<text.endIndex)
        else {
            XCTFail("SheetCommands could not be found in PostRollApp.swift, so "
                    + "this test is reading nothing and would pass on any file")
            return ""
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    func testEveryCommandButtonAsksForAWindowBeforeRaisingItsSheet() throws {
        let body = try commandsBody()

        // Each `Button("…") {` and what follows it up to the closing brace of
        // the action. Crude on purpose: the question is only whether the call
        // is in there at all.
        let buttons = body.components(separatedBy: "Button(").dropFirst()
        XCTAssertFalse(buttons.isEmpty,
                       "no command buttons were found at all, so this test is "
                       + "reading nothing")

        for button in buttons {
            let label = button.prefix(while: { $0 != ")" })
            let action = button.prefix(400)
            XCTAssertTrue(action.contains("openWindow(id:"),
                          "the command Button(\(label)) raises a sheet without "
                          + "asking for a window, so with the window closed it "
                          + "records a request and nothing appears (#884)")
        }
    }

    func testTheWindowIdIsNamedOnceRatherThanSpelledTwice() throws {
        let text = try source()

        XCTAssertTrue(text.contains("static let mainWindowID = \"main\""),
                      "the window id is no longer a named constant, so the scene "
                      + "and the commands that reopen it can drift apart and the "
                      + "drift is a command that silently opens nothing")
        // The literal itself, anywhere else in a window position, is what the
        // constant exists to prevent.
        XCTAssertFalse(text.contains("Window(\"PostRoll\", id: \"main\")"),
                       "the scene spells the window id as a literal again")
        XCTAssertFalse(text.contains("openWindow(id: \"main\")"),
                       "a command spells the window id as a literal again")
    }
}
