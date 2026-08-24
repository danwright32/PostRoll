import Foundation

/// What asking macOS for permission to notify produced (#879).
///
/// Its own type, and a pure one, because the thing worth testing is the
/// SENTENCE each outcome produces and `UNUserNotificationCenter` cannot be
/// reached from a test bundle at all: it raises rather than failing when there
/// is no real app around it (#707).
///
/// The reason this exists is that the answer used to be discarded. Every
/// notification PostRoll sends, every completion and every failed run, arrives
/// only if permission was granted, and a refusal produced the same evidence as
/// a working app: none. On the development machine on 2026-08-24, PostRoll had
/// no entry in macOS Notification settings at all, which is what a request that
/// never completed looks like from outside, and nothing in the app knew.
enum NotificationPermission: Equatable {

    /// Nothing has been asked yet. The state at launch, and never a verdict.
    case notAsked
    case granted
    /// Asked and told no. Recoverable by the person, in System Settings.
    case refused
    /// The request itself failed, which is a different thing from being told
    /// no and usually means the app never got as far as asking.
    case failed(String)

    static func outcome(granted: Bool, error: Error?) -> NotificationPermission {
        // The error wins. A request that failed can still report `granted` as
        // false, and reading that as a refusal would send somebody to a System
        // Settings switch that is not the problem (L11).
        if let error { return .failed(error.localizedDescription) }
        return granted ? .granted : .refused
    }

    /// What to say about it, or nil when there is nothing wrong.
    ///
    /// Each case names what is now silently not happening, rather than the
    /// state alone: "permission refused" tells a reader nothing about the
    /// captions they will never be told are ready.
    var complaint: String? {
        switch self {
        case .granted:
            return nil
        case .notAsked:
            return "permission has not been asked for, so nothing this app "
                + "announces can arrive."
        case .refused:
            return "notifications are not permitted, so every completion and "
                + "every failed run is announced to nobody. Turn PostRoll on in "
                + "System Settings > Notifications."
        case .failed(let reason):
            return "asking for permission failed (\(reason)), so no banner this "
                + "app sends can arrive, and this is not something System "
                + "Settings will show as switched off."
        }
    }

    /// Whether a banner sent right now could reach anybody.
    var canNotify: Bool { self == .granted }
}
