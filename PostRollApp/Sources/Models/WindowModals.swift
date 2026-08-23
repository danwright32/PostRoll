import Foundation

/// One presenter for the window, so a collision is a decision (#846).
///
/// `MainWindowView` bound three separate `.sheet` modifiers to the same view.
/// SwiftUI presents at most one sheet per view, so when two were asked for at
/// once, one of them silently did nothing and nothing said which. That was
/// survivable while all three were things Dan opened himself, because he could
/// only ask for one at a time; #840 ended it by letting a `postroll://` link
/// raise the New Event form at any moment, including while the build behind
/// warning is up.
///
/// Both losers were bad in different ways. A swallowed form is a link that
/// appears to do nothing. A swallowed build behind warning is the notice that
/// exists to stop a shipped fix looking like it never worked (#675), cleared by
/// an unrelated click. So neither is dropped: one is shown and the rest wait.

/// Who asked, which is the whole of what decides a collision.
///
/// Not a priority number. A number would have to be compared against every
/// other number, and the real rule has only two sides: Dan asked for this, or
/// something running on its own did.
enum ModalOrigin {
    /// A click, a keyboard shortcut, or a `postroll://` link Dan followed.
    /// Whatever he just asked for is what he expects to be looking at.
    case person
    /// A check that runs on its own schedule, such as the build freshness
    /// reading taken on every activation. It gets the screen when the screen is
    /// free and waits when it is not.
    case background
}

/// Something the window can put in front of everything else.
///
/// The `Kind` is deliberately separate from `Equatable`: two requests are the
/// SAME modal when they are the same kind, even when they carry different
/// values, so a second build freshness verdict REPLACES the one waiting rather
/// than queueing behind it. Without that, every activation would add another
/// copy of the same warning and Dan would dismiss it once per click into the
/// app, which is how a warning becomes something to wave away on reflex (L36).
protocol WindowModal: Identifiable, Equatable {
    associatedtype Kind: Equatable
    var kind: Kind { get }
    /// Whether this modal refuses to be pushed aside.
    ///
    /// A blocking modal is one whose whole job is to stop Dan carrying on: the
    /// store that could not be opened is the case, because the events are still
    /// there, saving is refused, and an app that looks empty would quietly
    /// discard edits. Everything else can be displaced and come back.
    var isBlocking: Bool { get }
}

extension WindowModal {
    var isBlocking: Bool { false }
}

/// What is on screen and what is waiting for it, with the rule between them.
///
/// A value type with no SwiftUI in it, so the decision can be tested without a
/// window. One implementation, used for both the sheets and the alerts: they
/// are the same defect on the same view, and a second copy of this rule would
/// be a second thing to keep correct.
struct ModalQueue<Modal: WindowModal> {

    /// The one being shown. Nothing else can be.
    private(set) var presented: Modal?

    /// Everything asked for that is not being shown, soonest first.
    private(set) var waiting: [Modal] = []

    /// Ask for a modal.
    ///
    /// The rule, in full:
    ///
    /// * Nothing showing: show it.
    /// * The same kind already showing or waiting: replace that one in place, so
    ///   the newest values win and nothing queues behind itself.
    /// * A blocking modal is showing: wait, whoever asked. Interrupting the
    ///   refusal to open the store with a New Event form would put Dan in front
    ///   of an app that cannot save what he types into it.
    /// * Dan asked (`.person`): show it, and put what was showing at the front
    ///   of the queue so he gets it back the moment he is done here.
    /// * Something in the background asked: wait at the back.
    mutating func request(_ modal: Modal, from origin: ModalOrigin) {
        // Replacing in place first, so neither branch below can produce a
        // second copy of a kind that is already accounted for.
        if presented?.kind == modal.kind {
            presented = modal
            return
        }
        if let index = waiting.firstIndex(where: { $0.kind == modal.kind }) {
            waiting[index] = modal
            // Still only waiting if that is where it was. A person asking again
            // for something already queued means they want it now.
            if modal.isBlocking || (origin == .person && presented?.isBlocking != true) {
                waiting.remove(at: index)
                promote(modal)
            }
            return
        }
        guard let showing = presented else {
            presented = modal
            return
        }
        // A blocking modal takes the screen from anything, whoever asked for
        // it. It is a refusal, so it has to be seen, and it cannot be waved
        // away to reveal what it was hiding. Its arrival is also the moment the
        // thing behind it stopped being safe to act on.
        if modal.isBlocking {
            promote(modal)
            return
        }
        if origin == .person, !showing.isBlocking {
            promote(modal)
        } else {
            waiting.append(modal)
        }
    }

    /// Show `modal`, putting whatever it displaced first in line to come back.
    ///
    /// Front rather than back, because the displaced one was already on screen:
    /// it has waited longest and Dan has already seen it.
    private mutating func promote(_ modal: Modal) {
        if let showing = presented {
            waiting.insert(showing, at: 0)
        }
        presented = modal
    }

    /// Take the presented modal away and show the next one waiting.
    ///
    /// Returns what came off the screen, so a caller that has to record the
    /// dismissal (the build behind warning does) is told exactly what was
    /// dismissed rather than reading the field back after it changed.
    ///
    /// A blocking modal refuses: it returns nil and nothing moves. Dismissal is
    /// the one thing it exists to say no to, and letting a caller take it away
    /// by asking twice would put the whole point of it behind a convention.
    ///
    /// `expected` is required, and it is not ceremony. A dismissal is a decision
    /// about the modal that was on the screen when it was taken, and by the time
    /// it arrives that may not be what is presented any more. One button press
    /// makes two changes whenever the button's own action raises or withdraws
    /// something: the action runs first and the queue promotes what was waiting,
    /// and only then does SwiftUI report the modal it tore down. Unaddressed,
    /// that report lands on the modal nobody has seen yet and takes it away,
    /// which is #855: pressing Try Again on the refusal to open the events also
    /// silently swallowed the code folder warning queued behind it. An action
    /// must be addressed by what the decision was made over (L166).
    @discardableResult
    mutating func dismissPresented(_ expected: Modal.Kind) -> Modal? {
        guard presented?.kind == expected else { return nil }
        guard presented?.isBlocking != true else { return nil }
        let dismissed = presented
        presented = waiting.isEmpty ? nil : waiting.removeFirst()
        return dismissed
    }

    /// Take a modal away whether it is showing or waiting, because the thing it
    /// was about has stopped being true.
    ///
    /// A rebuild while the app is open is exactly what the out of date sheet
    /// asked for, and a warning still queued afterwards says the fix did not
    /// work. Withdrawing is not dismissing: nobody saw it, so nothing is
    /// recorded against it.
    mutating func withdraw(_ kind: Modal.Kind) {
        waiting.removeAll { $0.kind == kind }
        if presented?.kind == kind {
            presented = waiting.isEmpty ? nil : waiting.removeFirst()
        }
    }
}

// MARK: - The window's sheets

/// The one sheet the main window can be showing.
enum WindowSheet: WindowModal {
    /// The New Event form, whether Dan opened it or a link did. The prefill
    /// lives on `AppState`, which is where every route to the form already put
    /// it, rather than being carried here as well: two places holding the same
    /// values is two places for them to disagree.
    case newEvent
    /// The list of days whose cached assets predate the current design (#293).
    case outdatedDesigns
    /// The running app is older than the code it was built from (#675).
    case buildBehind(BuildBehind)

    enum Kind { case newEvent, outdatedDesigns, buildBehind }

    var kind: Kind {
        switch self {
        case .newEvent: return .newEvent
        case .outdatedDesigns: return .outdatedDesigns
        case .buildBehind: return .buildBehind
        }
    }

    /// Identity for SwiftUI's `.sheet(item:)`, which rebuilds the sheet when it
    /// changes. The build behind case carries its verdict's id, so a newer
    /// verdict redraws rather than leaving the old times on screen.
    var id: String {
        switch self {
        case .newEvent: return "newEvent"
        case .outdatedDesigns: return "outdatedDesigns"
        case .buildBehind(let behind): return "buildBehind-\(behind.id)"
        }
    }
}

// MARK: - The window's alerts

/// The one alert the main window can be showing.
///
/// The same treatment as the sheets above and for the same reason (#846): these
/// were three separate `.alert` modifiers on one view, and two of them are
/// raised by launch checks that both run on every launch, so both can want the
/// screen within the same second.
enum WindowAlert: WindowModal {
    /// The code folder this build was made from cannot be used, so nothing can
    /// be generated (#652). Everything else in the app still works, so this is
    /// dismissible.
    case projectRoot(AppPaths.ProjectRootProblem)
    /// The store was read and what came back was not usable. The events may be
    /// recoverable from a backup, which is why this one carries an action
    /// (#441).
    case dataLoad(String)
    /// The store could not be read at all. Different from the case above: the
    /// events are still there and we cannot see them, saving is refused, and
    /// letting Dan past would leave him in an app that looks empty and quietly
    /// discards his edits.
    case storeUnavailable(String)

    enum Kind { case projectRoot, dataLoad, storeUnavailable }

    var kind: Kind {
        switch self {
        case .projectRoot: return .projectRoot
        case .dataLoad: return .dataLoad
        case .storeUnavailable: return .storeUnavailable
        }
    }

    /// Only the refusal to open the store. Its binding has always ignored
    /// dismissal; saying so here makes that a property of the alert rather than
    /// a detail of how one call site happened to be written, so it holds
    /// wherever the alert is presented from.
    var isBlocking: Bool {
        if case .storeUnavailable = self { return true }
        return false
    }

    var id: Kind { kind }
}

/// What each alert says.
///
/// Lifted out of the window when the three `.alert` modifiers became one
/// (#846). One modifier means one title and one message expression, and a
/// `switch` inside a SwiftUI string position is worse to read than a named
/// function beside the cases it is switching over.
enum WindowAlertText {

    static func title(_ alert: WindowAlert) -> String {
        switch alert {
        case .projectRoot: return LaunchProjectCheck.title
        case .dataLoad: return "Saved events could not be read"
        case .storeUnavailable: return "PostRoll cannot open your events"
        }
    }

    static func message(_ alert: WindowAlert) -> String {
        switch alert {
        case .projectRoot(let problem): return LaunchProjectCheck.message(problem)
        case .dataLoad(let message): return message
        case .storeUnavailable(let message): return message
        }
    }
}
