import Foundation

/// Who an event is billed to on screen (#689).
///
/// An event can have no organisation: a director hiring Dan to shoot a play is
/// not an organisation, and there is nothing to type. Every surface that used
/// to print `event.org` unconditionally then prints a blank, which is not a
/// missing value on screen, it is a gap that reads as a bug. The sidebar row
/// showed an empty line above the date, and VoiceOver announced "name, , date"
/// with a silent segment in the middle.
///
/// So the rule is written once here and every surface asks: the organisation
/// when there is one, the venue when there is not, and nothing at all when
/// there is neither. The venue rather than a placeholder, and for the same
/// reason the folder name uses it: it is true, it is useful, and "no
/// organisation" is a sentence nobody needs to read on every row.
enum EventCredit {

    /// What to show beside the date, or nil when there is nothing true to say.
    static func leading(org: String, venue: String) -> String? {
        for candidate in [org, venue] {
            let trimmed = FieldText.normalized(candidate)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The whole spoken row, with no empty segments in it.
    ///
    /// Built by joining what is actually there rather than by interpolating
    /// every field into a template: a template cannot tell an absent value from
    /// a present one, and the pause it leaves is indistinguishable from a
    /// VoiceOver fault.
    static func spokenRow(name: String, org: String, venue: String,
                          date: String, shootType: String, stage: String) -> String {
        var parts = [FieldText.normalized(name)]
        if let credit = leading(org: org, venue: venue) { parts.append(credit) }
        parts.append(date)
        parts.append(shootType)
        parts.append("stage \(stage)")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
