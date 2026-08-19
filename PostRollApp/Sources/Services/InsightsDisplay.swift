import Foundation

/// Which of three different screens Insights should be showing (#88).
///
/// An error state and an empty state are not the same screen. When
/// analytics.json cannot be read, the history is set aside and the app starts
/// with nothing, and the ordinary "no posts imported yet" view over the top of
/// that is a lie: it tells Dan to go and import, when what actually happened is
/// that his existing import could not be read and is sitting in a file next to
/// the store.
///
/// The failure therefore outranks emptiness, which is the whole rule.
enum InsightsDisplay {

    enum State: Equatable {
        /// The history could not be read. Carries the message to show.
        case failedToLoad(String)
        /// Read fine, genuinely nothing imported yet.
        case empty
        /// Read fine, has posts.
        case data
    }

    static func state(recoveryMessage: String?, postCount: Int) -> State {
        if let recoveryMessage, !recoveryMessage.isEmpty {
            return .failedToLoad(recoveryMessage)
        }
        return postCount == 0 ? .empty : .data
    }

    /// Whether the failure banner shows.
    static func showsRecoveryBanner(recoveryMessage: String?, postCount: Int) -> Bool {
        if case .failedToLoad = state(recoveryMessage: recoveryMessage, postCount: postCount) {
            return true
        }
        return false
    }

    // MARK: - What an import may claim (#439)

    /// Whether the import may be reported as a success, and the words for it.
    ///
    /// Two cases rather than one string, because the summary renders beside a
    /// green tick. The app now refuses to write over an analytics file it could
    /// not read, so "imported" and "kept" came apart: without this, Dan imports a
    /// Meta export, reads a tick saying 34 posts arrived, and finds them gone at
    /// next launch. Success is shown only once the write has actually landed (L12).
    enum ImportNotice: Equatable {
        /// On disk. Safe to show as done.
        case saved(String)
        /// Merged into this window only. Must never be drawn as a success.
        case notSaved(String)
    }

    static func importNotice(imported: Int, added: Int, updated: Int,
                             warnings: Int, save: StoreSaveOutcome) -> ImportNotice {
        let counts = "Imported \(imported) posts (\(added) new, \(updated) updated)"
        let lost = " These posts will be gone when you quit."

        switch save {
        case .saved:
            var text = counts + "."
            if warnings > 0 {
                text += " \(warnings) warning\(warnings == 1 ? "" : "s")."
            }
            return .saved(text)

        case .blocked:
            // The store refused the write on purpose: the file could not be read,
            // so its contents are unknown and must not be overwritten. Insights
            // is already showing that, but a tick over the top of it would say
            // the opposite on the same screen.
            return .notSaved(counts + " into this window, but nothing was saved: your "
                             + "imported history could not be read, so PostRoll will not "
                             + "write over it." + lost)

        case .failed(let reason):
            // Through Sentence because the reason comes from the file system and
            // may or may not end in a stop of its own.
            return .notSaved(counts + " but they could not be saved: "
                             + Sentence.closed(reason) + lost)
        }
    }

    /// What to say when a generated report could not be written, or nil when it
    /// was. Same rule as `importNotice`, for the screen next door: a report shown
    /// as recorded when the store refused the write is gone at next launch.
    static func unsavedReportNotice(save: StoreSaveOutcome) -> String? {
        switch save {
        case .saved:
            return nil
        case .blocked:
            return "The report was generated but not saved: your imported history "
                 + "could not be read, so PostRoll will not write over it. It will "
                 + "be gone when you quit."
        case .failed(let reason):
            return "The report was generated but could not be saved: "
                 + Sentence.closed(reason) + " It will be gone when you quit."
        }
    }

    /// Which edit was refused. The two leave opposite states behind: a band
    /// that was not saved is gone at next launch, an entry that was not cleared
    /// is back at next launch. One message for both would be wrong for one of
    /// them (L11).
    enum BandEdit {
        case set
        case cleared
    }

    /// What to say when a follower band edit could not be written, or nil when
    /// it was. Same rule as `unsavedReportNotice`: the picker moves the instant
    /// it is clicked, so a refused write is otherwise indistinguishable from a
    /// saved one (#712).
    static func unsavedBandNotice(save: StoreSaveOutcome, org: String,
                                  edit: BandEdit) -> String? {
        let subject: String
        let ending: String
        switch edit {
        case .set:
            subject = "The follower band for @\(org) was changed here"
            ending = " This change will be gone when you quit."
        case .cleared:
            subject = "The stored band for @\(org) was removed here"
            ending = " It will be back when you quit."
        }

        switch save {
        case .saved:
            return nil
        case .blocked:
            return subject + " but not saved: your imported history could not be "
                 + "read, so PostRoll will not write over it." + ending
        case .failed(let reason):
            return subject + " but could not be saved: "
                 + Sentence.closed(reason) + ending
        }
    }

    // MARK: - What a post row says (#469, #490)

    /// One engagement figure, as an SF Symbol plus a number.
    ///
    /// Symbols rather than emoji: emoji are forbidden in this app's copy, they
    /// render at whatever size and weight the font decides, and VoiceOver reads
    /// them as their unicode names. The name is what the accessible label uses,
    /// so the row can be read aloud as "likes 412" rather than "black heart
    /// suit 412" (#469).
    struct Metric: Equatable {
        let symbol: String
        let name: String
        let value: String
    }

    /// The figures a post row shows, in a fixed order so two posts read the
    /// same way, and skipping anything the export did not carry.
    ///
    /// `follows` and `durationSec` were persisted on every import and read by
    /// nothing, which is a field that looks alive to any is-this-used check
    /// while the purpose it was added for never happens (#490, L46). They are
    /// read here: follows is the figure that says a post brought someone in
    /// rather than merely being liked, and a reel's length is the thing Dan
    /// changes between one week and the next.
    static func metrics(likes: Int?, comments: Int?, saves: Int?, replies: Int?,
                        reach: Int?, follows: Int?, durationSec: Double?) -> [Metric] {
        var out: [Metric] = []
        if let likes    { out.append(Metric(symbol: "heart", name: "likes", value: "\(likes)")) }
        if let comments { out.append(Metric(symbol: "bubble.right", name: "comments",
                                            value: "\(comments)")) }
        if let saves    { out.append(Metric(symbol: "bookmark", name: "saves", value: "\(saves)")) }
        if let replies  { out.append(Metric(symbol: "arrowshape.turn.up.left", name: "replies",
                                            value: "\(replies)")) }
        if let reach    { out.append(Metric(symbol: "eye", name: "reach", value: "\(reach)")) }
        if let follows, follows > 0 {
            out.append(Metric(symbol: "person.badge.plus", name: "new followers",
                              value: "\(follows)"))
        }
        if let durationSec, durationSec > 0 {
            out.append(Metric(symbol: "timer", name: "length",
                              value: formattedDuration(durationSec)))
        }
        return out
    }

    /// A reel's length as a length of time rather than a number to decode.
    static func formattedDuration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }

    /// The whole row read as one sentence, for VoiceOver, because a row of
    /// glyphs and numbers is announced as noise otherwise.
    static func metricsLabel(_ metrics: [Metric]) -> String {
        metrics.map { "\($0.name) \($0.value)" }.joined(separator: ", ")
    }

    /// The window a saved report covers (#490).
    ///
    /// `dateRangeStart` and `dateRangeEnd` were written by every analysis and
    /// rendered nowhere, so a saved report could not say which weeks it was
    /// about, which is the only thing that tells two reports apart once there
    /// are several.
    static func reportRange(from start: Date, to end: Date,
                            calendar: Calendar = .current,
                            formatter: DateFormatter? = nil) -> String {
        let f = formatter ?? {
            let f = DateFormatter()
            f.dateFormat = "d MMM"
            return f
        }()
        let sameDay = calendar.isDate(start, inSameDayAs: end)
        return sameDay ? f.string(from: start)
                       : "\(f.string(from: start)) to \(f.string(from: end))"
    }
}

/// What the Posts list says when it has nothing to show (#463).
///
/// Out of the view so the wording can be pinned: the old sentence blamed the
/// search in every case, so a Stories or Feed segment that simply holds no
/// posts read as "No posts match \"\"" with empty quotes, which names a control
/// Dan never touched (L11).
enum InsightsPostsEmpty {
    static func message(searchText: String, filter: String) -> String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "No \(filter.lowercased()) posts in your imported history."
        }
        return "No posts match \"\(query)\"."
    }
}
