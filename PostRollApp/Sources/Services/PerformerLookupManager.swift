import Foundation
import Observation

/// Owns the two long lookups on the performers section, so neither dies with
/// the section that started it (#707).
///
/// The same shape #693 fixed for the programme notes search, on the two calls
/// that issue flagged and did not touch. Looking up handles and fetching
/// performers from a website both kept their progress, their elapsed clock and
/// their error message in the performers editor's own state, and that editor is
/// destroyed the moment another section of the accordion is opened. A run still
/// going, one that finished and one that failed then looked identical, because
/// all three showed nothing at all.
///
/// Switching events is the worse half: the screen is id tagged, so it remounts
/// and the binding the results were written through goes with it, and the run
/// completes into nothing.
///
/// Both lookups are here rather than in a manager each, because they act on one
/// list, from one section, and only one of them can sensibly run at a time:
/// fetching performers from a website REPLACES the list the handle lookup is
/// filling in.
@MainActor
@Observable
final class PerformerLookupManager {

    /// Which lookup, since one event can be between the two of them and the
    /// screen has to say which is going.
    enum Kind: String, CaseIterable {
        case handles
        case fromWeb

        /// What Dan sees while it runs.
        var label: String {
            switch self {
            case .handles: return "Looking up handles…"
            case .fromWeb: return "Reading the event page…"
            }
        }

        /// The same work, as a clause for a sentence about it stopping (#863).
        /// Separate from `label` because that one is a progress caption and this
        /// one has to read after an event's name.
        var workDescription: String {
            switch self {
            case .handles: return "looking up handles"
            case .fromWeb: return "reading the event page"
            }
        }
    }

    struct Run {
        var kind: Kind
        var startedAt: Date
        var elapsedSeconds: Int
        /// Why it ended badly, kept after the run so the message is still there
        /// when the section is reopened.
        var failure: String?
        /// What a handle lookup found, kept here rather than in the editor for
        /// the same reason: they are the run's result and Dan accepts them one
        /// at a time, so they have to outlive a section being closed.
        var suggestions: [PythonBridge.HandleSuggestion] = []
        /// The list as it was before a web fetch replaced it, so the undo
        /// survives too. An undo whose input died with the view is not an undo.
        var replaced: [Performer]?
        fileprivate var task: Task<Void, Never>?
    }

    /// One tracker per kind, so a handle lookup and a web fetch on the same
    /// event are separate runs rather than one overwriting the other's record.
    private var trackers: [Kind: JobTracker<Event.ID, Run>] = [:]

    /// Whether either lookup is still running (#862).
    ///
    /// Across every kind, because "is anything running" is the question being
    /// asked and one kind answering for both would be wrong in the direction
    /// that loses work. A kind with no tracker yet has never been started, so it
    /// contributes nothing rather than being treated as unknown.
    var hasWorkInFlight: Bool {
        trackers.values.contains { $0.hasWorkInFlight }
    }

    private func tracker(_ kind: Kind) -> JobTracker<Event.ID, Run> {
        if let existing = trackers[kind] { return existing }
        let made = JobTracker<Event.ID, Run>(elapsed: \.elapsedSeconds)
        trackers[kind] = made
        return made
    }

    func isRunning(_ kind: Kind, for id: Event.ID) -> Bool {
        tracker(kind).isActive(id)
    }

    /// Whether ANY lookup is going for this event. The two write to the same
    /// list, so the second must not start while the first is in flight: a web
    /// fetch REPLACES the list a handle lookup is filling in.
    func isBusy(_ id: Event.ID) -> Bool {
        Kind.allCases.contains { isRunning($0, for: id) }
    }

    func run(_ kind: Kind, for id: Event.ID) -> Run? { tracker(kind).job(for: id) }
    func failure(_ kind: Kind, for id: Event.ID) -> String? {
        tracker(kind).job(for: id)?.failure
    }
    func suggestions(for id: Event.ID) -> [PythonBridge.HandleSuggestion] {
        tracker(.handles).job(for: id)?.suggestions ?? []
    }

    func clearFailure(_ kind: Kind, for id: Event.ID) { tracker(kind).clearFailed(id) }

    /// Take one suggestion off the run once it has been applied or waved away.
    func dropSuggestion(named name: String, for id: Event.ID) {
        tracker(.handles).update(id) { $0.suggestions.removeAll { $0.name == name } }
    }

    func dropAllSuggestions(for id: Event.ID) {
        tracker(.handles).update(id) { $0.suggestions = [] }
    }

    /// How long either lookup may take before it is called stalled.
    ///
    /// Both are one model call over a handful of names. Generous rather than
    /// tight, for the reason every threshold in this app is: one that fires on
    /// ordinary runs teaches Dan to ignore it (L36). What it buys is that a
    /// call which never comes back becomes an error he can act on rather than
    /// an indicator that sits there forever (L110).
    static let deadline: TimeInterval = 300

    #if POSTROLL_TESTS
    var deadlineForTesting: TimeInterval = PerformerLookupManager.deadline
    private var activeDeadline: TimeInterval { deadlineForTesting }

    /// Test seams: the two calls, which really shell out to Python and cost
    /// money. A suite able to reach them is a suite that spends (L2).
    var lookUpHandles: @Sendable ([Performer], String, String, String) async throws
        -> [PythonBridge.HandleSuggestion] = {
        try await PythonBridge.shared.suggestHandles(performers: $0, org: $1, venue: $2, event: $3)
    }
    var fetchFromWeb: @Sendable (String) async throws -> [Performer] = {
        try await PythonBridge.shared.fetchWebPerformers(eventURL: $0)
    }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }

    let lookUpHandles: @Sendable ([Performer], String, String, String) async throws
        -> [PythonBridge.HandleSuggestion] = {
        try await PythonBridge.shared.suggestHandles(performers: $0, org: $1, venue: $2, event: $3)
    }
    let fetchFromWeb: @Sendable (String) async throws -> [Performer] = {
        try await PythonBridge.shared.fetchWebPerformers(eventURL: $0)
    }
    #endif

    // MARK: - Looking up handles

    /// Fill in what the handle book already knows, then search for the rest.
    ///
    /// The book pass is instant and is written to the stored event immediately,
    /// so it is not lost if the search that follows fails or is never seen.
    func startHandleLookup(eventID: Event.ID, org: String, venue: String,
                           eventName: String, appState: AppState) {
        guard !isBusy(eventID) else { return }

        // The book first, against the stored list, so what is written and what
        // is searched for are the same list.
        var filledFromBook = 0
        if var live = appState.events.first(where: { $0.id == eventID }),
           var stored = live.ocrResult {
            for index in stored.performers.indices
            where stored.performers[index].handle.isEmpty
                && !stored.performers[index].name.isEmpty {
                let saved = HandleBook.shared.handle(forPerformer: stored.performers[index].name)
                if !saved.isEmpty {
                    stored.performers[index].handle = saved
                    filledFromBook += 1
                }
            }
            if filledFromBook > 0 {
                live.ocrResult = stored
                appState.updateEvent(live)
            }
        }

        let missing = (appState.events.first(where: { $0.id == eventID })?
            .ocrResult?.performers ?? [])
            .filter { !$0.name.isEmpty && $0.handle.isEmpty }

        guard !missing.isEmpty else {
            // Everything came from the book. Still worth saying so, because a
            // lookup that did its whole job instantly and said nothing reads as
            // a lookup that did not run (L12).
            NotificationService.shared.notifyHandleLookupComplete(
                eventName: eventName, count: filledFromBook)
            return
        }

        begin(.handles, eventID: eventID)
        let lookUp = lookUpHandles
        let deadline = activeDeadline
        let task = Task { @MainActor [weak self] in
            do {
                let found = try await DeadlinedWork.run(within: deadline) {
                    try await lookUp(missing, org, venue, eventName)
                }
                guard !Task.isCancelled else { return }
                let useful = found.filter { $0.handle != nil }
                self?.tracker(.handles).update(eventID) { $0.suggestions = useful }
                self?.tracker(.handles).deactivate(eventID)
                NotificationService.shared.notifyHandleLookupComplete(
                    eventName: eventName, count: useful.count + filledFromBook)
            } catch is CancellationError {
                self?.tracker(.handles).remove(eventID)
            } catch {
                self?.fail(.handles, eventID: eventID, error: error, named: eventName)
            }
        }
        tracker(.handles).update(eventID) { $0.task = task }
    }

    /// Apply one suggestion to the stored event, and take it off the run.
    ///
    /// Written to the event rather than through a binding so it lands whether
    /// or not the screen that offered it still exists.
    func apply(_ suggestion: PythonBridge.HandleSuggestion, to eventID: Event.ID,
               in appState: AppState) {
        guard let handle = suggestion.handle,
              var live = appState.events.first(where: { $0.id == eventID }),
              var stored = live.ocrResult,
              let index = stored.performers.firstIndex(where: {
                  $0.name == suggestion.name && $0.handle.isEmpty
              })
        else {
            dropSuggestion(named: suggestion.name, for: eventID)
            return
        }
        stored.performers[index].handle = handle
        live.ocrResult = stored
        appState.updateEvent(live)
        dropSuggestion(named: suggestion.name, for: eventID)
    }

    // MARK: - Reading the event page

    func startWebFetch(eventID: Event.ID, url: String, eventName: String,
                       appState: AppState) {
        guard !isBusy(eventID) else { return }
        begin(.fromWeb, eventID: eventID)

        let fetch = fetchFromWeb
        let deadline = activeDeadline
        let task = Task { @MainActor [weak self] in
            do {
                let fetched = try await DeadlinedWork.run(within: deadline) { try await fetch(url) }
                guard !Task.isCancelled else { return }
                self?.replacePerformers(with: fetched, on: eventID, in: appState)
                self?.tracker(.fromWeb).deactivate(eventID)
                NotificationService.shared.notifyWebPerformersFetched(
                    eventName: eventName, count: fetched.count)
            } catch is CancellationError {
                self?.tracker(.fromWeb).remove(eventID)
            } catch {
                self?.fail(.fromWeb, eventID: eventID, error: error, named: eventName)
            }
        }
        tracker(.fromWeb).update(eventID) { $0.task = task }
    }

    /// Put the list back as it was before the web fetch replaced it.
    ///
    /// The snapshot lives on the run, so the undo survives the section closing
    /// and the event being switched. An undo whose only copy of what it
    /// reverses died with a view is not an undo at all (L97).
    func undoWebFetch(for eventID: Event.ID, in appState: AppState) {
        guard let previous = tracker(.fromWeb).job(for: eventID)?.replaced,
              var live = appState.events.first(where: { $0.id == eventID }),
              var stored = live.ocrResult else { return }
        stored.performers = previous
        live.ocrResult = stored
        appState.updateEvent(live)
        tracker(.fromWeb).remove(eventID)
    }

    private func replacePerformers(with fetched: [Performer], on eventID: Event.ID,
                                   in appState: AppState) {
        guard var live = appState.events.first(where: { $0.id == eventID }),
              var stored = live.ocrResult else { return }
        tracker(.fromWeb).update(eventID) { $0.replaced = stored.performers }
        stored.performers = fetched
        live.ocrResult = stored
        appState.updateEvent(live)
    }

    // MARK: - Shared bookkeeping

    private func begin(_ kind: Kind, eventID: Event.ID) {
        tracker(kind).begin(
            Run(kind: kind, startedAt: Date(), elapsedSeconds: 0, failure: nil),
            for: eventID)
    }

    private func fail(_ kind: Kind, eventID: Event.ID, error: Error, named eventName: String) {
        tracker(kind).update(eventID) {
            $0.failure = ProgramNotesMerge.failureMessage(error)
        }
        tracker(kind).markFailed(eventID)
        // Said out loud when he is not looking (#863).
        NotificationService.shared.notifyWorkFailed(
            work: kind.workDescription,
            eventName: eventName,
            reason: ProgramNotesMerge.failureMessage(error))
    }
}

/// Asked whenever PostRoll is about to quit or install an update (#862).
///
/// The phrase is a clause rather than a name, because it is dropped into a
/// sentence that already says what is happening to it.
extension PerformerLookupManager: BackgroundWork {
    var workPhrase: String { "a performer lookup is still running" }
}
