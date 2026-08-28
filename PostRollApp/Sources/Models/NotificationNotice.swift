import Foundation

/// What the window says about notifications, or nothing (#894).
///
/// #890 made the app keep the answer to whether it may notify, and write a
/// complaint to the log when it may not. Nothing on screen said it, and the log
/// is not a surface Dan reads. Somebody who closes the window and relies on a
/// banner to tell him a run finished had no way to learn that no banner can
/// come, and a feature that fails only in the situation it was built for, in
/// silence, is indistinguishable from a run that is still going.
///
/// A pure type for the same reason `NotificationPermission` is one: what is
/// worth testing is the SENTENCE each state produces, and
/// `UNUserNotificationCenter` cannot be reached from a test bundle at all.
enum NotificationNotice {

    /// The banner's sentence, or nil when there is nothing to say.
    ///
    /// `hasAsked` is not the same question as the permission itself, and both
    /// are needed. `.notAsked` is the state at launch, before the request has
    /// come back, and a banner on every launch is the false alarm that teaches
    /// somebody to ignore this one. `.notAsked` AFTER the app has asked is the
    /// reported symptom itself: a request that never completed, which until now
    /// read as an ordinary launch.
    ///
    /// The sentence comes from `NotificationPermission.complaint`, which is
    /// what the log already carries, rather than a second wording beside it:
    /// two sentences about one condition drift, and the drift is invisible
    /// because nobody reads both. It is written to follow a log prefix, so the
    /// first letter is raised here, which is the window's business rather than
    /// the complaint's.
    static func message(permission: NotificationPermission, hasAsked: Bool) -> String? {
        guard hasAsked, let complaint = permission.complaint else { return nil }
        return complaint.prefix(1).uppercased() + complaint.dropFirst()
    }
}
