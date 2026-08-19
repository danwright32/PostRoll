import Foundation

/// Adding the tags that go on every post to a week's captions, in one place.
///
/// Two callers need this and they are not near each other: the review screen
/// folds them into the draft when it opens, and `CaptionWorkManager` folds them
/// into what a fresh whole-week run produced, which happens with no screen
/// watching at all (#718). Written twice, the two would drift, and the
/// difference would show up as tags appearing on a regenerated week but not on
/// an existing one, or the reverse.
enum GlobalTagMerge {

    /// Add each tag to every day that has content and does not already carry
    /// it, and say whether anything changed.
    ///
    /// Only where it is missing, so opening the screen twice, or re-running a
    /// week, does not double a tag up. The Bool is the difference between a
    /// merge that did something and one that found nothing to do, so a caller
    /// can leave the store alone rather than writing an identical copy of it.
    @discardableResult
    static func apply(_ tags: [String], to week: inout WeekGenerationResult,
                      for event: Event) -> Bool {
        guard !tags.isEmpty else { return false }
        var changed = false
        for day in week.daysWithContent(in: event) {
            guard var caption = week[day] else { continue }
            var dayChanged = false
            for tag in tags where !caption.hashtags.contains(tag) {
                caption.hashtags.append(tag)
                dayChanged = true
            }
            if dayChanged {
                week[day] = caption
                changed = true
            }
        }
        return changed
    }
}
