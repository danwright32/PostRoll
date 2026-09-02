import SwiftUI

/// Every owner of work that outlives a screen, in ONE list (#718).
///
/// Each of these exists because a long run used to live in a view's own state
/// and died with it. There are seven now, and the number only goes up, which is
/// the problem this solves: the app injected them in one place and the test
/// harness that renders whole screens spelled the same list out again. A view
/// reads its owner with `@Environment(T.self)`, and SwiftUI TRAPS when one is
/// missing, so forgetting the second list does not fail a check, it crashes the
/// screen. That is what happened when `OCRReflowManager` was added: the app was
/// fine and the sweep that renders every stage died.
///
/// A list kept by hand beside another list is a list they can disagree about,
/// and the disagreement is invisible until something renders (L41, L96). So
/// there is one list, here, and both the app and the harness use it. Adding an
/// owner is one line in one place.
///
/// A struct of references rather than a class: the owners are `@Observable`
/// classes, so their identity is stable across the `@State` that holds this,
/// and nothing observes the container itself.
@MainActor
struct AppOwners {
    var generation = GenerationManager()
    var ocr = OCRManager()
    var export = ExportManager()
    /// The programme notes web search (#693).
    var notes = ProgramNotesManager()
    /// The two performer lookups (#707).
    var lookup = PerformerLookupManager()
    /// The Insights CSV import and the paid analysis (#718).
    var insights = InsightsWorkManager()
    /// The "describe the correction" reflow on the review screen (#718).
    var reflow = OCRReflowManager()
    /// The runs started from the caption review screen (#718).
    var captionWork = CaptionWorkManager()
    /// The layout gallery's render of a day's candidate collages (#718).
    var collageLayouts = CollageLayoutLoader()
    /// The automatic audience figures fetch (#1004).
    var accountNumbers = AccountNumbersManager()
}

extension AppOwners {
    /// Join the handle lookups to the figures fetch (#1004).
    ///
    /// Done here rather than at either end, because this is the one place that
    /// already knows about both, and neither of them should have to know about
    /// the other: the lookup manager stays ignorant of audience figures, and
    /// the fetch stays ignorant of where a handle came from.
    ///
    /// Called once when the app builds its owners. Idempotent, because the
    /// assignment replaces rather than appends.
    func connectTheHandleTrigger() {
        lookup.onHandlesSettled = { [accountNumbers] handles in
            accountNumbers.handlesSettled(handles)
        }
        // And the export, which copies what it needs before detaching, gets
        // the note the fetch leaves behind. Re-read on every trigger rather
        // than once, because the note changes with each run.
        accountNumbers.onNoteChanged = { [export] note in
            export.accountNumbersNote = note
        }
    }

    /// Everything running right now, phrased for a sentence (#862).
    ///
    /// Derived from this struct rather than written out again, for the same
    /// reason the injection below is: a second list of the owners is a list the
    /// two can disagree about. Before this, the one place that asked whether it
    /// was safe to quit named three of the nine by hand, and the other six were
    /// invisible to it.
    var workInFlight: [String] { BackgroundWorkScan.inFlight(of: self) }
}

/// What is running, for the screens that have to say so.
///
/// A value rather than the container, because `AppOwners` is a struct of
/// references and putting it in the environment would hand every reader a copy
/// of the references with no observation of its own. Read inside a view body,
/// the properties behind it are `@Observable`, so the body that injects this
/// re-runs when work starts or stops and nowhere else has to remember to.
private struct WorkInFlightKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var workInFlight: [String] {
        get { self[WorkInFlightKey.self] }
        set { self[WorkInFlightKey.self] = newValue }
    }
}

extension View {
    /// Put every work owner into the environment.
    ///
    /// Used by the app and by every test that renders a whole screen, so the
    /// two cannot come apart. Injecting an owner a particular screen never
    /// reads costs nothing; leaving one out crashes it.
    func withAppOwners(_ owners: AppOwners) -> some View {
        self
            .environment(owners.generation)
            .environment(owners.ocr)
            .environment(owners.export)
            .environment(owners.notes)
            .environment(owners.lookup)
            .environment(owners.insights)
            .environment(owners.reflow)
            .environment(owners.captionWork)
            .environment(owners.collageLayouts)
            // What is running, derived from the nine above rather than named
            // again by whoever needs it (#862).
            .environment(\.workInFlight, owners.workInFlight)
    }
}
