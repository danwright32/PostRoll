import Foundation

/// A `postroll://` link, read into the fields the New Event sheet asks for
/// (#840).
///
/// Downbeat already holds the event name, the organisation, the venue, the room
/// and the date, and already prints all five into an OmniFocus task note. This
/// is the other end of that: the note carries one link, and clicking it opens
/// the sheet already filled rather than leaving the five to be retyped.
///
/// Everything here is a pure reading of text. Nothing it returns has been
/// written anywhere: the sheet is the review step, and it is what keeps a stale
/// or wrong link visible before it becomes an event.
enum DeepLink {

    /// The scheme the built app registers. Spelled once, and read by the guard
    /// that checks the BUILT bundle declares it, so the two cannot drift.
    static let scheme = "postroll"

    /// The one action this version knows. A link asking for anything else is
    /// refused by name rather than treated as this one.
    static let newEventAction = "new"

    /// The five fields, in the order they are checked.
    ///
    /// One list rather than a sweep written out per field, so a field added
    /// here is covered by the placeholder guard without anybody remembering to
    /// extend it (L96).
    private static let fields = ["name", "org", "venue", "room", "date", "booking"]

    // MARK: - What a good link says

    /// A new event, as the link describes it. Not an `Event`: nothing is
    /// created until Create is pressed.
    struct EventDraft: Equatable, Hashable {
        var name: String
        var org: String
        var venue: String
        /// The specific hall or room, which the URL calls `room` because that
        /// is the word on Downbeat's side. `Event` calls it `venueContext`.
        var venueContext: String
        var date: Date
        /// Downbeat's id for the booking, which is per SHOW rather than per
        /// booking: a three night run emits three links carrying three ids, and
        /// therefore makes three events.
        var bookingID: UUID
    }

    // MARK: - What a bad link says

    /// Why a link opened nothing.
    ///
    /// A case per cause, each with its own sentence, because the sentence is
    /// the only thing Dan gets: the link came out of a task note he cannot see
    /// the source of, and "that link did not work" names nothing he can fix
    /// (L11).
    enum Refusal: Equatable, Error {
        /// Not a PostRoll link at all. Unreachable through LaunchServices,
        /// which only delivers the scheme the bundle declares, and reachable
        /// through every other caller of this parser.
        case notOurScheme(String)
        /// `postroll://` with nothing after it.
        case noAction
        /// A link asking for something this version cannot do.
        case unknownAction(String)
        /// A Downbeat template placeholder that never got substituted.
        case unsubstitutedToken(field: String, value: String)
        /// A field that has to be there and is not.
        case missing(field: String)
        case unreadableDate(String)
        case unreadableBooking(String)

        var message: String {
            switch self {
            case .notOurScheme(let scheme):
                return "That link is a \(scheme): link, not a PostRoll one, so nothing was opened."
            case .noAction:
                return "That link says postroll: and nothing else, so there is nothing to open."
            case .unknownAction(let action):
                return "That link asks PostRoll to \(action), which this version does not know how to do."
            case .unsubstitutedToken(let field, let value):
                return "That link's \(field) still reads \(value), which is a Downbeat placeholder "
                    + "rather than a value. Nothing was filled in. Fix the task template in Downbeat."
            case .missing(let field):
                return "That link carries no \(field), and PostRoll will not invent one, so nothing was opened."
            case .unreadableDate(let value):
                return "That link's date reads \(value). PostRoll expects a real day written as "
                    + "eight digits, YYYYMMDD."
            case .unreadableBooking(let value):
                return "That link's booking id reads \(value), which is not an id PostRoll can "
                    + "match a second click against."
            }
        }
    }

    // MARK: - Where a click lands

    /// What clicking a link does, given what is already in the store.
    ///
    /// Three outcomes and no fourth: there is no case for "nothing happened",
    /// because a click that opened nothing and said nothing is
    /// indistinguishable from one that opened something off screen (L10).
    enum Landing: Equatable {
        /// Open the sheet, filled in. Nothing has been written.
        case newEvent(EventDraft)
        /// This link already has an event. Select it, and say so.
        case alreadyCreated(id: Event.ID, message: String)
        /// The link says nothing usable, and this is why.
        case refused(String)
    }

    /// Reading a link and matching it against the store, in one call.
    ///
    /// Matching is on the booking id ALONE. Anything coarser (the org, the
    /// venue, the run) would fold nights two and three of a run into night one,
    /// which is the case the task tree emits most often.
    static func landing(for url: URL,
                        existing: [Event],
                        calendar: Calendar = .current) -> Landing {
        switch draft(from: url, calendar: calendar) {
        case .failure(let refusal):
            return .refused(refusal.message)
        case .success(let draft):
            // `$0.downbeatBookingID == draft.bookingID` and not a comparison
            // that two nils satisfy: every event in the store today has none,
            // and a nil matching a nil would select whichever happened to be
            // first rather than opening a sheet.
            if let already = existing.first(where: { $0.downbeatBookingID == draft.bookingID }) {
                return .alreadyCreated(id: already.id, message: alreadyCreatedMessage(for: already))
            }
            return .newEvent(draft)
        }
    }

    /// What the window says when a link is clicked a second time.
    ///
    /// Names the event, because the commonest way to click twice is to click
    /// while that event is already on screen, and a selection that changes
    /// nothing visible reads as a link that did nothing at all.
    static func alreadyCreatedMessage(for event: Event) -> String {
        "\(event.name) was already created from this link, so it is selected here "
            + "rather than made a second time."
    }

    /// What the window says about a click that opened no sheet.
    ///
    /// Both outcomes speak. A refusal has to, or a broken link is silence; and a
    /// selection has to, because the commonest way to click a link twice is to
    /// click it while that event is already on screen, where selecting it again
    /// changes nothing visible.
    struct Notice: Equatable, Identifiable {
        enum Kind: Equatable {
            /// The link did something, and it was not the something expected.
            case handled
            /// The link did nothing, and this is why.
            case refused
        }

        let kind: Kind
        let message: String

        var id: String { message }
    }

    // MARK: - Reading one

    /// The draft a link describes, or why it describes none.
    ///
    /// The calendar is a parameter rather than `.current` read inside, because
    /// `YYYYMMDD` names a DAY and which instant a day starts at is decided
    /// entirely by the time zone (L504).
    static func draft(from url: URL, calendar: Calendar = .current) -> Result<EventDraft, Refusal> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.notOurScheme(url.scheme ?? ""))
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.noAction)
        }
        guard let action = components.host, !action.isEmpty else {
            return .failure(.noAction)
        }
        guard action.lowercased() == newEventAction else {
            return .failure(.unknownAction(action))
        }

        let items = components.queryItems ?? []
        func raw(_ key: String) -> String? {
            items.last { $0.name == key }?.value
        }

        // Placeholders first, and across every field, before any of them is
        // read as a value. An unsubstituted `<<venueName>>` in an OPTIONAL
        // field is not the same thing as that field being empty: empty says
        // Downbeat had nothing to put there, a placeholder says it had
        // something and the template failed (L214). Storing the second as the
        // first puts template source into a folder name and a caption.
        for field in fields {
            guard let value = raw(field) else { continue }
            if value.contains("<<") || value.contains(">>") {
                return .failure(.unsubstitutedToken(field: field, value: value))
            }
        }

        guard let dateText = raw("date"), !dateText.isEmpty else {
            return .failure(.missing(field: "date"))
        }
        guard let date = day(dateText, calendar: calendar) else {
            return .failure(.unreadableDate(dateText))
        }

        guard let bookingText = raw("booking"), !bookingText.isEmpty else {
            return .failure(.missing(field: "booking"))
        }
        guard let bookingID = UUID(uuidString: bookingText) else {
            return .failure(.unreadableBooking(bookingText))
        }

        // Folded the same way a paste into the form itself is (#688). These
        // values reach folder names, captions and the handle book's keys, and a
        // break in the middle of one renders as a space that nothing says is
        // really a newline.
        return .success(EventDraft(
            name: FieldText.singleLine(raw("name") ?? ""),
            org: FieldText.singleLine(raw("org") ?? ""),
            venue: FieldText.singleLine(raw("venue") ?? ""),
            venueContext: FieldText.singleLine(raw("room") ?? ""),
            date: date,
            bookingID: bookingID
        ))
    }

    /// `YYYYMMDD` as the start of that day, or nil when it is not a day.
    ///
    /// The round trip is the point. `Calendar.date(from:)` turns the 31st of
    /// February into the 3rd of March without complaint, so a link carrying a
    /// day that does not exist would silently become a shoot date nobody typed.
    private static func day(_ text: String, calendar: Calendar) -> Date? {
        guard text.count == 8, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else {
            return nil
        }
        guard let year = Int(text.prefix(4)),
              let month = Int(text.dropFirst(4).prefix(2)),
              let day = Int(text.suffix(2)) else { return nil }

        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        guard let date = calendar.date(from: parts) else { return nil }

        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }
}
