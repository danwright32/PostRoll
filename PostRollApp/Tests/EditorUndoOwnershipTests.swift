import XCTest
import AppKit

/// Holding Cmd+Z in a caption crashed the app outright (#196).
///
/// `SpellCheckingTextEditor` set `allowsUndo = true` and supplied no undo
/// manager, so every editor registered its edits on the WINDOW's shared stack.
/// NSUndoManager keeps an unowned reference to an action's target, and these
/// editors are torn down constantly (switching day, switching event, dismissing
/// a sheet) while the window lives on. Key repeat walked past the live editor's
/// own operations into a stale entry and sent `_undoRedoTextOperation:` to a
/// freed NSTextView.
///
/// Each editor owning its own manager fixes the crash and the second defect
/// underneath it: undo inside one caption could undo an edit made in a
/// different caption or in the blog body.
@MainActor
final class EditorUndoOwnershipTests: XCTestCase {

    private func makeTextView(_ coordinator: SpellCheckingTextEditor.Coordinator) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        SpellCheckingTextEditor.configure(tv, delegate: coordinator,
                                          font: .systemFont(ofSize: 12), textColor: .labelColor)
        return tv
    }

    func testTheEditorUsesItsOwnUndoManagerNotTheWindowsOne() {
        let coordinator = SpellCheckingTextEditor.Coordinator()
        let tv = makeTextView(coordinator)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(tv)

        XCTAssertTrue(tv.undoManager === coordinator.editorUndoManager,
                      "the editor has to own its stack, or it outlives the text view")
        XCTAssertFalse(tv.undoManager === window.undoManager,
                       "the window's stack lives as long as the window and holds unowned targets")
    }

    func testTwoEditorsDoNotShareAnUndoStack() {
        let a = SpellCheckingTextEditor.Coordinator()
        let b = SpellCheckingTextEditor.Coordinator()

        XCTAssertFalse(a.editorUndoManager === b.editorUndoManager,
                       "undo in one caption must not reach an edit made in another")
        XCTAssertTrue(makeTextView(a).undoManager === a.editorUndoManager)
        XCTAssertTrue(makeTextView(b).undoManager === b.editorUndoManager)
    }

    func testTearingDownAnEditorLeavesNothingRegisteredOnTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let coordinator = SpellCheckingTextEditor.Coordinator()

        autoreleasepool {
            let tv = makeTextView(coordinator)
            window.contentView?.addSubview(tv)
            // A real edit, registered the way typing registers one.
            tv.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
            tv.removeFromSuperview()
        }

        XCTAssertFalse(window.undoManager?.canUndo ?? false,
                       "an operation left on the window's stack points at a freed text view")
    }

    func testReplacingTheTextFromOutsideDropsTheStaleUndoHistory() {
        let coordinator = SpellCheckingTextEditor.Coordinator()
        let tv = makeTextView(coordinator)
        tv.insertText("typed by hand", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(coordinator.editorUndoManager.canUndo, "precondition: there is history to lose")

        // What a regeneration writing a fresh caption in does.
        SpellCheckingTextEditor.replaceTextExternally(tv, with: "a regenerated caption",
                                                      coordinator: coordinator)

        XCTAssertEqual(tv.string, "a regenerated caption")
        XCTAssertFalse(coordinator.editorUndoManager.canUndo,
                       "history whose ranges no longer describe the buffer must not survive")
    }

    func testAnExternalReplacementKeepsTheCaretWhereItWas() {
        let coordinator = SpellCheckingTextEditor.Coordinator()
        let tv = makeTextView(coordinator)
        tv.string = "0123456789"
        tv.setSelectedRange(NSRange(location: 4, length: 2))

        SpellCheckingTextEditor.replaceTextExternally(tv, with: "abcdefghij", coordinator: coordinator)

        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 2))
    }

    func testAnExternalReplacementClampsACaretPastTheNewEnd() {
        // The replacement can be shorter than what was there. A stale range
        // would be out of bounds, which throws rather than merely looking wrong.
        let coordinator = SpellCheckingTextEditor.Coordinator()
        let tv = makeTextView(coordinator)
        tv.string = "0123456789"
        tv.setSelectedRange(NSRange(location: 8, length: 2))

        SpellCheckingTextEditor.replaceTextExternally(tv, with: "abc", coordinator: coordinator)

        XCTAssertEqual(tv.string, "abc")
        let range = tv.selectedRange()
        XCTAssertLessThanOrEqual(range.location + range.length, 3)
    }
}
