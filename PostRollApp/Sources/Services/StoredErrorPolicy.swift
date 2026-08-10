import Foundation

/// When a stored generation error stops being a claim about the current state.
///
/// `mediaErrors` and `weekResult.errors` used to be replaced only by another
/// generation run, so re-linking every photo an error named left the review
/// screen showing the same six failures about files the event no longer
/// referenced (#181). An error is a record of one run against one set of
/// inputs; once those inputs change, it has to stop presenting as current.
///
/// Clearing (rather than marking stale) is the shape chosen because the day
/// then has no error AND no assets, which the generation screen already renders
/// as "not generated" rather than as success.
enum StoredErrorPolicy {

    /// The key the blog's errors are stored under, alongside the day names.
    static let blogKey = "blog"

    /// Every error key whose inputs include one of `files`: a day that lists the
    /// file in its photo grid or in a standalone media slot, plus the blog when
    /// the file is one of its photos.
    ///
    /// Matching is structural (which day actually references the file), never a
    /// substring search of the error text, so an unrelated day whose message
    /// happens to contain a similar path is not cleared by accident.
    static func daysReferencing(_ files: Set<URL>, in event: Event) -> Set<String> {
        guard !files.isEmpty else { return [] }
        var keys: Set<String> = []
        for (key, day) in event.days {
            let referenced = day.photoPaths.contains(where: files.contains)
                || MediaSlot.allCases.contains { slot in
                    if let url = day[slot] { return files.contains(url) }
                    return false
                }
                || day.audioPath.map(files.contains) == true
            if referenced { keys.insert(key) }
        }
        if event.blogPhotoPaths.contains(where: files.contains) { keys.insert(blogKey) }
        return keys
    }

    /// Drops the stored generation errors for `days` from both stores. Days not
    /// listed keep theirs, and nothing is invented in place of the dropped
    /// error: no caption and no preview path is added, so the day reads as not
    /// generated rather than as a success.
    static func clearingErrors(in event: Event, forDays days: Set<String>) -> Event {
        guard !days.isEmpty else { return event }
        var ev = event
        for key in days { ev.mediaErrors.removeValue(forKey: key) }
        // A warning is a record of the same run against the same inputs, so it
        // goes stale for exactly the same reason the error does.
        for key in days { ev.mediaWarnings.removeValue(forKey: key) }
        if var week = ev.weekResult {
            for key in days { week.errors.removeValue(forKey: key) }
            ev.weekResult = week
        }
        return ev
    }
}
