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
