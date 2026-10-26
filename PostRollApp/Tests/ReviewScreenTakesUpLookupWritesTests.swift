import XCTest
import SwiftUI
import AppKit

/// An applied handle suggestion shows on the open review screen.
///
/// Since #707 the performer lookups write to the stored event rather than
/// through the screen, so they land whether or not the screen still exists.
/// Nothing brought those writes back into the draft the screen shows. Dan
/// pressed the check beside Aurora Mendez's suggestion on 2026-10-26: the store
/// took `@mendezviolin`, the suggestion left the list, and her field stayed
/// empty, so it read as a press that did nothing. The next edit on the screen
/// would then have persisted the stale draft back over the applied handle.
///
/// Hosted for real, because the defect is in what the screen does with a
/// change underneath it, which no test of the rule alone can see (L3).
@MainActor
final class ReviewScreenTakesUpLookupWritesTests: XCTestCase {

    private func event() -> Event {
        var event = HostedControlLegibilityTests.sampleEvent(stage: .ocrDone)
        var result = OCRResult()
        result.performers = [
            Performer(name: "AyseDeniz Gokcin", role: "Piano"),
            Performer(name: "Aurora Mendez", role: "Violin 1"),
        ]
        event.ocrResult = result
        return event
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private func fieldValues(in view: NSView) -> [String] {
        var values: [String] = []
        if let field = view as? NSTextField { values.append(field.stringValue) }
        if let text = view as? NSTextView { values.append(text.string) }
        for sub in view.subviews { values.append(contentsOf: fieldValues(in: sub)) }
        return values
    }

    func testAnAppliedHandleSuggestionShowsInTheOpenReviewScreen() throws {
        let event = event()
        let appState = HostedControlLegibilityTests.scratchAppState(event)
        let owners = AppOwners()
        // The figures fetch it would trigger shells out to Python (L2).
        owners.lookup.onHandlesSettled = nil
        let book = HandleBook(defaults: UserDefaults(
            suiteName: "review-adopts-\(UUID().uuidString)")!)

        let host = NSHostingView(rootView: OCRReviewView(event: event, book: book)
            .environment(appState)
            .withAppOwners(owners))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        pump()

        // The control: the reader sees the fields, and the handle is not there
        // yet, so a pass below cannot come from reading nothing (L1).
        let before = fieldValues(in: host)
        XCTAssertTrue(before.contains("Aurora Mendez"),
                      "the performer fields were not found, so this test reads nothing: \(before)")
        XCTAssertFalse(before.contains("@mendezviolin"))

        owners.lookup.apply(
            PythonBridge.HandleSuggestion(name: "Aurora Mendez", handle: "@mendezviolin"),
            to: event.id, in: appState)
        pump()

        let stored = appState.events.first { $0.id == event.id }?
            .ocrResult?.performers.first { $0.name == "Aurora Mendez" }?.handle
        XCTAssertEqual(stored, "@mendezviolin", "the suggestion was never applied to the store")
        XCTAssertTrue(fieldValues(in: host).contains("@mendezviolin"),
                      "the handle was saved but the open screen still shows the field empty")
    }

    /// Taking up the stored result must not drop the handles the book guessed.
    ///
    /// The screen fills empty handles from the book when it opens, and those
    /// guesses live only in the draft until the first edit persists it. A
    /// refresh that simply replaced the draft with the store would blank them.
    func testTakingUpAnAppliedHandleKeepsTheBooksGuessOnAnotherRow() throws {
        let event = event()
        let appState = HostedControlLegibilityTests.scratchAppState(event)
        let owners = AppOwners()
        owners.lookup.onHandlesSettled = nil
        let book = HandleBook(defaults: UserDefaults(
            suiteName: "review-adopts-\(UUID().uuidString)")!)
        book.setEntry(name: "AyseDeniz Gokcin", value: "@adpianist", in: .performer)

        let host = NSHostingView(rootView: OCRReviewView(event: event, book: book)
            .environment(appState)
            .withAppOwners(owners))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        pump()
        XCTAssertTrue(fieldValues(in: host).contains("@adpianist"),
                      "the book's guess was never shown, so its survival proves nothing")

        owners.lookup.apply(
            PythonBridge.HandleSuggestion(name: "Aurora Mendez", handle: "@mendezviolin"),
            to: event.id, in: appState)
        pump()

        let shown = fieldValues(in: host)
        XCTAssertTrue(shown.contains("@mendezviolin"))
        XCTAssertTrue(shown.contains("@adpianist"),
                      "taking up the applied handle blanked the book's guess on another row")
    }
}
