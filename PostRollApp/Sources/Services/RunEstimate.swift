import Foundation

/// How long a long run is expected to take, and whether anybody measured it
/// (#1189).
///
/// `LongRunIndicator` shows an estimate beside the elapsed clock. Four of them
/// were string literals at their call sites, chosen rather than measured, and
/// since #1164 they sit beside `RepairRetryEstimate`, which IS derived from
/// timed calls. A chosen figure standing next to a measured one reads as a
/// measurement, and nothing at the call site said otherwise.
///
/// So every estimate is declared here and carries its provenance. That is the
/// whole point: a reader who wants to know whether "~2 to 5 min" is a reading
/// or a guess can see which, in one place, and shipping a measurement later is
/// a one-line change here rather than a hunt through the views.
///
/// ## What it does NOT do
///
/// It does not change what the person sees. Labelling a guess on screen is a
/// product decision and this is not one. What it changes is what the CODE
/// claims, which is where the next person to act on the number looks.
///
/// It also does not affect the stalled state. `LongRunIndicator` decides that
/// from `silenceThreshold` and the run's own step file, never from the
/// estimate, so a wrong estimate misleads a reader without making a healthy run
/// read as stalled. #1189 said it would; it does not, and saying so accurately
/// is worth more than repeating it.
enum RunEstimate {

    /// Where a figure came from.
    enum Provenance: Equatable {
        /// Derived from timed calls, with the readings in a committed fixture.
        case measured(fixture: String)
        /// Chosen, and there is a command that would measure it. The entry
        /// names its own remedy rather than being a note that it is not ideal
        /// (L111), and a test holds that command to existing.
        case chosen(wouldBeMeasuredBy: String)
        /// Chosen, and nothing here knows how to measure it cheaply yet.
        ///
        /// Its own case rather than a `chosen` with an invented command.
        /// Pointing at something that cannot be run is worse than saying
        /// nothing: it reads as a plan, and the first person to follow it finds
        /// there is no such thing (L109). Carries WHY, so the next person
        /// starts from what is actually in the way.
        case chosenAndNotYetMeasurable(because: String)
    }

    struct Figure: Equatable {
        let text: String
        let provenance: Provenance
    }

    /// A full week of captions. Several sequential Claude calls, one per day.
    static let captionWeek = Figure(
        text: "~3 to 6 min",
        provenance: .chosen(wouldBeMeasuredBy:
            "tools/measure_blog_calls.py --pass week"))

    /// The story graphics for a week. Local rendering, no model calls.
    static let storyGraphics = Figure(
        text: "~1 min",
        provenance: .chosenAndNotYetMeasurable(because:
            "local rendering driven from the app rather than a Python entry "
            + "point anything here can start, so timing it means running the "
            + "app and there is no module to point a tool at"))

    /// A blog rewrite from feedback. Sequential calls whose count depends on
    /// the post, which is why a range is the right shape here.
    static let blogRevision = Figure(
        text: "~2 to 5 min",
        provenance: .chosen(wouldBeMeasuredBy: "tools/measure_blog_calls.py --pass blog"))

    /// Swapping the photographs in a post. Image carrying calls, one per photo.
    static let blogPhotoSwap = Figure(
        text: "~1 to 3 min",
        provenance: .chosen(wouldBeMeasuredBy: "tools/measure_blog_calls.py --pass photos"))

    /// Updating the app. The build runs the whole test suite before installing,
    /// which is where the minutes go.
    ///
    /// Found by the sweep rather than by reading: #1189 named two estimates,
    /// the sweep found four, and this fifth one is in a different file again.
    /// That is why the rule is enforced over the view layer rather than over
    /// the two files the issue happened to mention (L30, L247).
    static let appUpdate = Figure(
        text: "~3 to 6 min",
        provenance: .chosenAndNotYetMeasurable(because:
            "the updater is a detached script that runs the whole suite and "
            + "then replaces the running app, so timing it means letting it "
            + "finish and there is nothing left running to record the reading"))

    /// Every figure this app shows, so a sweep can enumerate them rather than
    /// being handed a list somebody has to keep current (L96, L41).
    static let all: [(name: String, figure: Figure)] = [
        ("captionWeek", captionWeek),
        ("storyGraphics", storyGraphics),
        ("blogRevision", blogRevision),
        ("blogPhotoSwap", blogPhotoSwap),
        ("appUpdate", appUpdate),
    ]
}
