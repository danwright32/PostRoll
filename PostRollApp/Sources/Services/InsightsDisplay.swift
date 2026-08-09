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
}
