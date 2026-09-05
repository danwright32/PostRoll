import Foundation

/// The post metadata that is not the post: SEO description and details block.
///
/// Every generated post ships `<meta name="description" content="">`.
/// Squarespace falls back to `og:description`, which takes the opening prose,
/// so the summary search engines and AI crawlers see for the Whitacre post is
/// "The hall wasn't open yet. Singers in black were already out on 57th
/// Street...". Good writing, useless as a summary. The one hand-written post on
/// the site that HAS a description proves the mechanism: filling the field
/// fixes both tags (#283).
///
/// **Neither string may live inside the post body.** A fact block in `body`
/// gets sent to Claude to be reworded by `_fix_missing_contractions` (it never
/// has a contraction), pushes the CTA out of last place so the second-person
/// guard starts rewriting the closing line of every revised post, and is
/// counted as prose by `blog_quality`, whose invented-number check then flags
/// the date. So these are separate fields, rendered at copy and export time
/// only, never entering the AI round trip.
///
/// Mirrors `postroll/blog_meta.py`. The two are kept in parity by hand, so
/// `tests/fixtures/blog_meta.json` states the cases once and both sides assert
/// against it (#104, #186).
enum BlogMeta {

    /// Squarespace shows a description between these lengths. Outside the band
    /// the field is either refused or truncated mid-sentence, and neither is
    /// visible from inside the app.
    static let seoMinChars = 50
    static let seoMaxChars = 300

    /// Closes the description. Constant rather than derived, and long enough on
    /// its own that the 50 character floor cannot be breached by a sparse event.
    static let brandTail = "Concert and theater photography in New York by Dan Wright."

    static let photographer = "Dan Wright"

    /// Month names spelled out rather than taken from a `DateFormatter`. Both
    /// languages must produce the same bytes, and a locale-dependent month name
    /// is exactly the drift the shared fixture exists to prevent.
    static let months = ["January", "February", "March", "April", "May", "June",
                         "July", "August", "September", "October", "November",
                         "December"]

    /// The characters the global writing rule bans, as escapes so this file has
    /// nothing for the pre-push style hook to catch. They are stripped at
    /// intake because the hook only reads source, never runtime output: an
    /// event name Dan typed with an em dash would otherwise ship one into the
    /// page metadata.
    private static let emDash = "\u{2014}"
    private static let enDash = "\u{2013}"

    // MARK: - Event convenience

    static func seoDescription(event: Event) -> String {
        seoDescription(name: event.name, org: event.org, venue: event.venue,
                       venueContext: event.venueContext, isoDate: event.isoDate,
                       shootType: event.shootType.pythonValue)
    }

    static func seoTitle(event: Event) -> String {
        seoTitle(name: event.name, org: event.org, venue: event.venue)
    }

    static func detailsBlock(event: Event) -> String {
        detailsBlock(name: event.name, org: event.org, venue: event.venue,
                     venueContext: event.venueContext, isoDate: event.isoDate,
                     shootType: event.shootType.pythonValue,
                     eventURL: event.eventURL)
    }

    /// What a search result actually shows. Google truncates around 60
    /// characters and Squarespace accepts 100, so the useful ceiling is the
    /// smaller one: a title cut by the search engine loses the photographer,
    /// which is the half the page is trying to be found for (#1368).
    static let seoTitleMaxChars = 60

    /// The page title for one post, always inside the ceiling.
    ///
    /// Squarespace leaves this field empty by default and builds the page
    /// title from the post title and the site's title format, and PostRoll's
    /// post titles are shaped for the blog rather than for a search result: a
    /// long venue name pushes the photographer and the event off the end.
    ///
    /// Three facts, in the order somebody searching would recognise them: what
    /// the event was, where it was, and who photographed it. Shortened by a
    /// declared ladder rather than a blind cut, so the venue goes before the
    /// credit does and the name is cut last, at a word boundary.
    ///
    /// The organisation stands in for a missing event name rather than leaving
    /// a hole, and a post with neither is still a correct shorter title rather
    /// than a string with an empty half (L67).
    ///
    /// Mirrors `postroll/blog_meta.seo_title`; `tests/fixtures/blog_meta.json`
    /// states every case once and both sides assert against it.
    static func seoTitle(name: String, org: String, venue: String) -> String {
        let name = clean(name)
        let org = clean(org)
        let venue = clean(venue)
        let subject = name.isEmpty
            ? orgWorthNaming(name: name, org: org, venue: venue) : name

        let ladder: [(String, String, Bool)] = [
            (subject, venue, true),
            (subject, "", true),
            (subject, venue, false),
            (subject, "", false),
        ]
        for (trySubject, tryVenue, credited) in ladder {
            let text = composeTitle(trySubject, tryVenue, credited)
            if !text.isEmpty, text.count <= seoTitleMaxChars { return text }
        }

        // The subject itself is the problem, so it is cut to the budget the
        // rest leaves, at a word boundary, and never mid word.
        let fixed = composeTitle("", "", true).count
        let budget = max(seoTitleMaxChars - fixed, 0)
        var trimmed = String(subject.prefix(budget))
        if trimmed.contains(" ") {
            trimmed = String(trimmed[..<trimmed.range(of: " ", options: .backwards)!.lowerBound])
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        return composeTitle(trimmed, "", true)
    }

    /// `Perpetual Light at Carnegie Hall | Dan Wright`, or whichever half is
    /// there. Empty when there is nothing to name at all, which the caller
    /// reads as this rung of the ladder not applying.
    private static func composeTitle(_ subject: String, _ venue: String,
                                     _ credited: Bool) -> String {
        let left = [subject, venue].filter { !$0.isEmpty }.joined(separator: " at ")
        guard !left.isEmpty else { return credited ? photographer : "" }
        return credited ? "\(left) | \(photographer)" : left
    }

    // MARK: - The two strings

    /// The `<meta name="description">` for one post, always inside the band.
    ///
    /// Shortens by a declared ladder rather than a blind truncation, so what
    /// gets dropped is the least useful fact rather than whatever happened to
    /// be last: the room goes first, then the organisation, and only then is
    /// the event name cut at a word boundary. The date and venue always survive.
    static func seoDescription(name: String, org: String, venue: String,
                               venueContext: String, isoDate: String,
                               shootType: String) -> String {
        let name = clean(name)
        let venue = clean(venue)
        let room = clean(venueContext)
        // An unmapped shoot type is still describable: "Photographs of X at Y"
        // is true of every shoot. The Python twin raises here instead, which is
        // right for a CLI; a published page is better served by a vaguer fact
        // than by a raw enum value, and `testEveryShootTypeHasProse` proves no
        // real case reaches this.
        let label = shootTypeLabel(shootType)
        let lead = label.isEmpty ? "Photographs" : "\(label) photographs"
        let dateDisplay = formatDate(isoDate)
        let org = orgWorthNaming(name: name, org: clean(org), venue: venue)

        let ladder: [(String, String, String)] = [
            (name, org, venuePhrase(venue: venue, room: room)),
            (name, org, venuePhrase(venue: venue, room: "")),
            (name, "", venuePhrase(venue: venue, room: "")),
        ]
        for (tryName, tryOrg, tryVenue) in ladder {
            let text = compose(lead: lead, name: tryName, org: tryOrg,
                               venuePhrase: tryVenue, dateDisplay: dateDisplay)
            if text.count <= seoMaxChars { return text }
        }

        // Still too long, so the event name itself is the problem. Cut it to
        // the budget the rest of the sentence leaves, at a word boundary, so
        // the summary never ends mid-word.
        let bare = venuePhrase(venue: venue, room: "")
        let fixed = compose(lead: lead, name: "", org: "",
                            venuePhrase: bare, dateDisplay: dateDisplay).count
        let budget = seoMaxChars - fixed - " of ".count
        return compose(lead: lead, name: trimToWordBoundary(name, budget),
                       org: "", venuePhrase: bare, dateDisplay: dateDisplay)
    }

    /// The plain factual statement of who photographed what, where and when.
    ///
    /// One `label: value` per line. A line whose value is missing is omitted
    /// entirely rather than printed empty: a label with nothing after it reads
    /// as a fact that failed to load rather than one the event does not have.
    static func detailsBlock(name: String, org: String, venue: String,
                             venueContext: String, isoDate: String,
                             shootType: String, eventURL: String) -> String {
        let name = clean(name)
        let venue = clean(venue)
        let room = clean(venueContext)
        let lines: [(String, String)] = [
            ("Event", name),
            ("Presented by", orgWorthNaming(name: name, org: clean(org), venue: venue)),
            ("Venue", venuePhrase(venue: venue, room: room)),
            ("Date", formatDate(isoDate)),
            ("Photographed", shootTypeLabel(shootType)),
            // The event page, which is where the program lives. Not the
            // photographer's own site: this block is rendered ON that site.
            ("Program", clean(eventURL)),
            ("Photographer", photographer),
        ]
        return lines.filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }

    // MARK: - Surfacing it (#284)

    /// One metadata string, with the label its control and its export section
    /// both use, so the two surfaces cannot name the same thing differently.
    struct CopyField: Equatable {
        let label: String
        /// What the control's tooltip says, and where the string is pasted.
        let help: String
        let text: String
    }

    /// The strings that get their own copy control on the blog review screen.
    ///
    /// Declared here rather than assembled in the view, because #205 is the
    /// lesson this repeats: the title was generated, stored and shown, and Dan
    /// still typed it by hand every time, because the surface he copies from
    /// carried the body alone. Writing these only into `0. Blog/` would be the
    /// same defect with a new field name.
    static func copyFields(event: Event) -> [CopyField] {
        [
            CopyField(label: "SEO title",
                      help: "Paste into the page's SEO title field",
                      text: seoTitle(event: event)),
            CopyField(label: "SEO description",
                      help: "Paste into the page's SEO description field",
                      text: seoDescription(event: event)),
            // Says where the block GOES, not where it must not (#1367). It
            // read "Paste below the post, outside the post body", which is
            // PostRoll's own constraint (the block stays out of `body` so it
            // never enters the review passes) and has no referent in
            // Squarespace, whose editor has one content area. Dan, pasting a
            // post on 2026-09-04: "I'm not sure what to do with the details
            // block."
            CopyField(label: "Details block",
                      help: "Paste as its own text block at the end of the post",
                      text: detailsBlock(event: event)),
        ]
    }

    /// The export folder's copy, beside the draft rather than inside it.
    ///
    /// Its own file: a labelled section appended to `draft.md` would be pasted
    /// into the post along with everything else, which is the exact hazard
    /// these fields exist to avoid (#283).
    static let exportFileName = "post-metadata.txt"

    static func exportFileText(event: Event) -> String {
        var lines = [
            "POST METADATA",
            "",
            "These are NOT part of the post. Pasting them into the body sends "
            + "them through the review passes, which reword them.",
        ]
        for field in copyFields(event: event) {
            lines.append("")
            // Named exactly as its button is, not shouted into a header: the
            // file and the review screen are one vocabulary, and a person
            // matching the two by eye should not have to translate.
            lines.append("\(field.label) (\(field.help))")
            lines.append(field.text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Pieces

    /// Trim, and replace banned dashes with punctuation that is allowed.
    ///
    /// A spaced dash is a sentence break, so it becomes a comma; a tight one
    /// joins two words, so it becomes a space. Stripped rather than deleted, so
    /// the words on either side survive.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for dash in [emDash, enDash] {
            text = text.replacingOccurrences(of: " \(dash) ", with: ", ")
            text = text.replacingOccurrences(of: dash, with: " ")
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `2026-04-04` becomes `April 4, 2026`, or an empty string if unreadable.
    ///
    /// Empty rather than the raw text: this reaches a published page, and a
    /// dropped clause is a visible gap where a raw value is an assertion that
    /// happens to be wrong. The Python twin raises instead, which is right for
    /// a CLI; here the only caller is `Event.isoDate`, which cannot be
    /// malformed, so this is the unreachable-by-construction side.
    static func formatDate(_ iso: String) -> String {
        let parts = iso.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return "" }
        return "\(months[month - 1]) \(day), \(year)"
    }

    /// How this shoot is named in prose.
    ///
    /// The prose has to match what Dan actually witnessed: calling a photo call
    /// a performance is a factual error about the evening, not a wording
    /// preference. Routed through `ShootType` so the switch below is exhaustive
    /// and a case added later is a build error rather than a raw value on a
    /// published page.
    static func shootTypeLabel(_ pythonValue: String) -> String {
        guard let type = ShootType.allCases.first(where: { $0.pythonValue == pythonValue })
        else { return "" }
        switch type {
        case .fullShow:  return "Performance"
        case .photoCall: return "Photo call"
        case .rehearsal: return "Rehearsal"
        case .combo:     return "Rehearsal and performance"
        }
    }

    /// The org, unless naming it would just repeat something already said.
    ///
    /// Two cases, both of which read as a stutter in a one-sentence summary: an
    /// org with the same name as the event (the rule `brand_text.detail_lines`
    /// already applies to the templates), and an org with the same name as the
    /// venue, which is every resident company at its own theater.
    private static func orgWorthNaming(name: String, org: String, venue: String) -> String {
        guard !org.isEmpty else { return "" }
        let folded = org.lowercased()
        if folded == name.lowercased() || folded == venue.lowercased() { return "" }
        return org
    }

    /// `Stern Auditorium, Carnegie Hall`, or whichever half exists.
    private static func venuePhrase(venue: String, room: String) -> String {
        [room, venue].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func compose(lead: String, name: String, org: String,
                                venuePhrase: String, dateDisplay: String) -> String {
        var text = lead
        if !name.isEmpty { text += " of \(name)" }
        if !org.isEmpty {
            // No leading comma when there is no name, or the sentence opens
            // with "photographs , presented by".
            text += name.isEmpty ? " presented by \(org)" : ", presented by \(org)"
        }
        if !venuePhrase.isEmpty { text += " at \(venuePhrase)" }
        if !dateDisplay.isEmpty { text += ", \(dateDisplay)" }
        return "\(text). \(brandTail)"
    }

    private static func trimToWordBoundary(_ text: String, _ budget: Int) -> String {
        guard budget > 0 else { return "" }
        // No early return when the name already fits: this is only reached once
        // the ladder has failed, and mirroring Python's unconditional
        // `name[:budget].rsplit(" ", 1)[0]` keeps the two byte-identical rather
        // than identical only on the inputs anyone happened to test.
        let cut = String(text.prefix(budget))
        let head = cut.contains(" ") ? String(cut[..<cut.range(of: " ", options: .backwards)!.lowerBound])
                                     : cut
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
    }
}
