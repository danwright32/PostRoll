import Foundation

/// Turning per-day media failures into one sentence for the export screen (#262).
///
/// `generate_media.py` reports a failure per day and exits zero, so a run that
/// lost a day looks identical to a clean one from the process's point of view.
/// The export path read none of it, which meant an export could report success
/// over a folder that was quietly missing an asset.
///
/// Both the day and its reason are named. Naming the day alone was the original
/// decision and it has been reversed (#1405): the day says where to look, and
/// the reason is the only thing that says whether looking will help. Sending
/// Dan to the log instead sent him nowhere, because he does not read logs.
enum MediaErrorSummary {

    /// The keys of a per-day report, in week order, with any non-day key last.
    ///
    /// A dictionary has no order, so without this the same trouble reads
    /// differently on each run and looks like a different problem. A key that
    /// is not a day name (Python can report a run-level failure) still has to
    /// appear, or the message claims fewer problems than there are.
    private static func orderedKeys(_ report: [String: String]) -> [String] {
        let days = report.keys
            .compactMap { DayName(rawValue: $0) }
            .sorted { DayName.allCases.firstIndex(of: $0)! < DayName.allCases.firstIndex(of: $1)! }
            .map(\.rawValue)
        return days + report.keys.filter { DayName(rawValue: $0) == nil }.sorted()
    }

    private static func displayName(_ key: String) -> String {
        DayName(rawValue: key)?.displayName ?? key
    }

    /// One sentence naming which days failed, or nil when none did.
    ///
    /// Every entry counts. Before #265 this was not true: Python filed a note
    /// here for a day that rendered perfectly well with an OPTIONAL input
    /// missing, so the caller had to guess which entries were real failures by
    /// checking whether the day had produced any files. Warnings now have their
    /// own field, so `errors` means failed and nothing else.
    ///
    /// Nil rather than an empty string, so a caller cannot put an empty banner
    /// on every successful export, which is how a real warning stops being read.
    static func sentence(_ errors: [String: String]) -> String? {
        let keys = orderedKeys(errors)
        guard !keys.isEmpty else { return nil }

        let lines = keys.map { "\(displayName($0)): \(reason(day: $0, raw: errors[$0] ?? ""))" }
        let subject = keys.count == 1 ? "That day's" : "Those days'"
        return lines.joined(separator: "\n")
             + "\n\n\(subject) graphics could not be generated, so the export "
             + "folder is missing them. Regenerate once the reason above is "
             + "dealt with."
    }

    /// What one failed day says for itself: what happened, then what to do
    /// about it when that is known.
    ///
    /// The reason used to be dropped here and the sentence said "Check the log
    /// for why" instead (#1405). That was #262's decision, on the premise that
    /// a reason is a wall of ffmpeg stderr telling Dan nothing he can act on.
    /// Two things retired that premise, and both are re-measurable rather than
    /// asserted (L316). The reasons are SHORT: the 17 real failures recorded in
    /// `tests/fixtures/real_failure_text.json` run 22 to 311 characters, median
    /// 153, the longest being a seven line ffmpeg dump. And the recognised ones
    /// are no longer raw: `GenerationFailureText` turns them into a sentence
    /// naming the step that fixes it, which the generation screen has shown for
    /// some time while this screen alone still threw it away.
    ///
    /// What it cost, measured on 2026-09-11: an export failed because a reel
    /// had no layout seed, this banner named Thursday and nothing else, and it
    /// was answered by re-exporting 150 photographs from Lightroom, which was
    /// neither the cause nor a remedy for it.
    ///
    /// The raw reason LEADS and the hint follows, rather than the hint standing
    /// in for it. A hint is a guess about which failure this is, and one that
    /// guesses wrong sends the diagnosis somewhere unrelated, so the text the
    /// machine actually produced stays on the screen beside it.
    ///
    /// Both halves go through `Sentence.closed`: Python's own wording carries
    /// no terminator and Cocoa's does, so the joiner owns the stop rather than
    /// either producer (#405).
    private static func reason(day: String, raw: String) -> String {
        let hint = GenerationFailureText.summary(day: day, raw: raw).text
        let said = Sentence.closed(raw)
        return hint.isEmpty ? said : "\(said) \(Sentence.closed(hint))"
    }

    /// What was worth saying about a day that rendered anyway, or nil when
    /// there was nothing.
    ///
    /// The reason is quoted, and the sentence after it says plainly that the
    /// folder is complete: a warning that reads like a loss is the defect this
    /// split exists to fix. This paragraph used to draw a contrast with a
    /// failure's reason, which it called ffmpeg stderr telling Dan nothing he
    /// can act on. There is no contrast left to draw: `sentence` above now
    /// carries its reasons the same way, for the reasons recorded there.
    ///
    /// That closing sentence names NO cause, and used to (#824). It said the day
    /// was exported "without the missing input", which was true of the one thing
    /// this carried when it was written, a chosen photo that had moved. It now
    /// also carries a Friday title card that failed, where nothing was missing
    /// and an encode did not run, and the sentence went on asserting a cause it
    /// could not know. The cause belongs to the line above, written by the code
    /// that knows it.
    static func warningSentence(_ warnings: [String: String]) -> String? {
        let keys = orderedKeys(warnings)
        guard !keys.isEmpty else { return nil }

        // Each reason is closed, so the sentence after the list does not run into
        // the last one. Python's own wording for these carries no terminator
        // ("Thursday black and white photo not found: /photos/x.jpg"), which is
        // confirmed at postroll/media/missing_media.py rather than assumed (#405).
        let lines = keys.map { "\(displayName($0)): \(Sentence.closed(warnings[$0] ?? ""))" }
        let subject = keys.count == 1 ? "That day was" : "Those days were"
        return lines.joined(separator: "\n")
             + "\n\n\(subject) exported anyway, so nothing is missing from the "
             + "folder."
    }
}
