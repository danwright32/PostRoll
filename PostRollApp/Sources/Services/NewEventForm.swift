import Foundation

/// The one place a new event is built out of what the New Event sheet holds
/// (#840).
///
/// Its own type rather than a block inside the sheet's Create button, because
/// two things now fill that form: Dan typing, and a `postroll://` link. Both
/// have to fold their text the same way and both have to decide the same thing
/// about the booking id, and a rule spelled once in a view is a rule the second
/// caller spells slightly differently.
enum NewEventForm {

    /// The event Create makes.
    ///
    /// Every one of the four text fields is a single line field, so a paste (or
    /// a link) carrying a break in the MIDDLE is folded rather than only
    /// trimmed (#688). The form renders one as a gap that looks like a space,
    /// so nothing on screen would say the value was broken, and these values
    /// reach folder names, captions and the handle book's keys.
    ///
    /// `bookingID` has no default. A caller that forgot it would get an event
    /// silently missing the key a second click matches on, and the failure
    /// would surface much later as a duplicate event rather than here as a
    /// compile error (L168).
    static func event(name: String,
                      org: String,
                      venue: String,
                      venueContext: String,
                      date: Date,
                      shootType: ShootType,
                      bookingID: UUID?) -> Event {
        Event(
            name: FieldText.singleLine(name),
            org: FieldText.singleLine(org),
            venue: FieldText.singleLine(venue),
            venueContext: FieldText.singleLine(venueContext),
            date: date,
            shootType: shootType,
            downbeatBookingID: bookingID
        )
    }

    /// The event Edit Details saves (#1448): the four text fields replaced and
    /// folded the way Create folds them, everything else left as it was.
    ///
    /// An event with anything on disk keeps the folder it was written under,
    /// pinned here before the fields that name it change. One with nothing
    /// written yet follows its new details, so a Duplicate edited into a second
    /// night gets its own folder rather than the first night's.
    static func edited(_ event: Event,
                       name: String,
                       org: String,
                       venue: String,
                       venueContext: String) -> Event {
        var edited = event
        if edited.folderName == nil && hasWrittenToDisk(event) {
            edited.folderName = EventFolder.name(for: event)
        }
        edited.name = FieldText.singleLine(name)
        edited.org = FieldText.singleLine(org)
        edited.venue = FieldText.singleLine(venue)
        edited.venueContext = FieldText.singleLine(venueContext)
        return edited
    }

    /// Whether a folder named after this event may exist: previews rendered,
    /// a week generated (the step that renders them), or an export run.
    private static func hasWrittenToDisk(_ event: Event) -> Bool {
        !event.previewMediaPaths.isEmpty || event.weekResult != nil
            || event.exportPath != nil
    }
}
