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
                      bookingID: UUID?,
                      orgOffGraphics: Bool) -> Event {
        Event(
            name: FieldText.singleLine(name),
            org: FieldText.singleLine(org),
            venue: FieldText.singleLine(venue),
            venueContext: FieldText.singleLine(venueContext),
            orgOffGraphics: keepsOff(org: org, asked: orgOffGraphics),
            date: date,
            shootType: shootType,
            downbeatBookingID: bookingID
        )
    }

    /// The event Edit Details saves (#1448): the four text fields replaced and
    /// folded the way Create folds them, whether the organisation is kept off
    /// the graphics, and the shoot type while it is not yet fixed, everything
    /// else left as it was.
    ///
    /// An event with anything on disk keeps the folder it was written under,
    /// pinned here before the fields that name it change. One with nothing
    /// written yet follows its new details, so a Duplicate edited into a second
    /// night gets its own folder rather than the first night's.
    static func edited(_ event: Event,
                       name: String,
                       org: String,
                       venue: String,
                       venueContext: String,
                       orgOffGraphics: Bool,
                       shootType: ShootType) -> Event {
        var edited = event
        if edited.folderName == nil && event.hasFilesOnDisk {
            edited.folderName = EventFolder.name(for: event)
        }
        edited.name = FieldText.singleLine(name)
        edited.org = FieldText.singleLine(org)
        edited.venue = FieldText.singleLine(venue)
        edited.venueContext = FieldText.singleLine(venueContext)
        edited.orgOffGraphics = keepsOff(org: org, asked: orgOffGraphics)
        if !event.shootTypeIsFixed { edited.shootType = shootType }
        return edited
    }

    /// The switch is stored on only while there is an organisation to keep off.
    /// Left on under a cleared name, it would quietly keep the next
    /// organisation typed in off the graphics.
    private static func keepsOff(org: String, asked: Bool) -> Bool {
        asked && !FieldText.singleLine(org).isEmpty
    }
}

extension NewEventForm {
    /// What Edit Details says beside a shoot type it will not change.
    static let shootTypeFixedReason = "Shoot type is fixed once photos are assigned."

    /// Why a save asking for `asked` cannot change the type, judged against the
    /// event as it is now: photos assigned while the sheet was open fix it, and
    /// a save must say so rather than quietly keep the old type.
    static func shootTypeRefusal(before: Event, asked: ShootType) -> String? {
        before.shootTypeIsFixed && asked != before.shootType ? shootTypeFixedReason : nil
    }
}

extension Event {
    /// Whether shoot type can no longer change (Dan, 2026-10-20).
    ///
    /// Shoot type is read only when the captions, blog and graphics are made,
    /// so until any photo or clip is chosen for a day or the blog, and nothing
    /// has been made, there is nothing built for the old type. #1448 kept it out
    /// of Edit Details entirely; this is the part of that rule's reason that
    /// still holds.
    var shootTypeIsFixed: Bool {
        hasFilesOnDisk || !blogPhotoPaths.isEmpty || days.values.contains { day in
            !day.photoPaths.isEmpty || MediaSlot.allCases.contains { day[$0] != nil }
        }
    }

    /// Whether a folder named after this event may exist: previews rendered,
    /// a week generated (the step that renders them), or an export run.
    var hasFilesOnDisk: Bool {
        !previewMediaPaths.isEmpty || weekResult != nil || exportPath != nil
    }
}
