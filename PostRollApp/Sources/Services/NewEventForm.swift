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
}
