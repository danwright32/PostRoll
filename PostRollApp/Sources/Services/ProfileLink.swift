import Foundation

/// One way to reach an account's Instagram profile (#973).
///
/// The programme review screen already opened a performer's profile from a URL
/// the research step stored and verified. The collaborator panel had no stored
/// URL for a candidate, only the handle, so it has to build the address from
/// the handle. Those are two routes to the same place, so there is one piece of
/// behaviour here and both screens call it, rather than a second
/// implementation growing beside the first (L263).
enum ProfileLink {

    /// Where a profile lives. Named once rather than typed at each use.
    private static let profileRoot = "https://www.instagram.com/"

    /// The address of this account's profile, or nil when there is nothing
    /// worth opening.
    ///
    /// Nil is what makes a handle render as plain text, which is deliberate: a
    /// dead link that looks live is worse than no link, because the only way to
    /// discover it is to press it and land on an error page.
    ///
    /// The path component comes from `CaptionBlocks.bareUsername` and nothing
    /// else. A stored handle can be `name`, `@name` or a pasted
    /// `https://instagram.com/name/`, and that is the one thing that turns all
    /// three into the same component; interpolating the stored string would put
    /// a sigil or a whole URL inside the path.
    ///
    /// Linkability is `PythonBridge.isRealHandle`, the read time test already
    /// applied on nine other surfaces: shaped like a username AND not one of
    /// the sentinels recorded when a lookup found nobody. Both halves are
    /// needed and neither answers the other, and reaching for it here keeps one
    /// rule with one implementation rather than a tenth spelling.
    static func url(handle: String, storedProfileURL: String? = nil) -> URL? {
        // A checked address beats a constructed one, in both directions. The
        // research step confirmed this URL against the real account; the
        // constructed one is only a convention, so it stands even where the
        // handle beside it is a display name the shape rule would refuse.
        if let checked = webAddress(storedProfileURL) { return checked }

        guard PythonBridge.isRealHandle(handle) else { return nil }
        return URL(string: profileRoot + CaptionBlocks.bareUsername(handle) + "/")
    }

    /// A stored value only counts as an address if it is one that opens in a
    /// browser.
    ///
    /// A present but unusable value falls through to the convention rather than
    /// being opened, because those are different situations and only one of
    /// them names a place worth going: `URL(string:)` will happily build a
    /// `file:` or `javascript:` URL out of a stored string, and this value is
    /// handed straight to `NSWorkspace`. Falling through still names the same
    /// account, so nothing is silently redirected somewhere else (L214).
    private static func webAddress(_ raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The checked addresses these performers carry, keyed the way the account
    /// book keys a handle (#987).
    ///
    /// One place that turns performer records into a lookup, rather than each
    /// surface walking the list its own way: the panel below ranks by that key
    /// and holds nothing else that could reach a performer.
    ///
    /// A performer with no stored address contributes no entry, so a miss and
    /// an empty string cannot come to mean different things at different call
    /// sites.
    static func checked(in performers: [Performer]) -> [String: String] {
        var book: [String: String] = [:]
        for performer in performers {
            let key = AccountBook.key(performer.handle)
            guard !key.isEmpty,
                  let stored = performer.profileURL?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !stored.isEmpty
            else { continue }
            book[key] = stored
        }
        return book
    }

    /// The checked address for one handle, or nil when there is none.
    ///
    /// The same book as above, asked about a single account: a screen that
    /// holds a handle and the day's performers has no other way to reach it,
    /// and asking here rather than indexing the book at each call site keeps
    /// the keying in one place.
    static func checkedProfile(for handle: String, in performers: [Performer]) -> String? {
        checked(in: performers)[AccountBook.key(handle)]
    }

    /// What a screen reader says about the control.
    ///
    /// Names whose profile it opens, matching the "Edit numbers for <handle>"
    /// pattern beside it in the collaborator panel. "Link" would say what it is
    /// rather than where it goes.
    /// A performer can carry a checked profile URL and no handle at all, so the
    /// name can be empty here. Interpolating it would read as a possessive with
    /// nobody in front of it.
    static func accessibilityLabel(handle: String) -> String {
        let name = CaptionBlocks.bareUsername(handle)
        guard !name.isEmpty else { return "Open this profile on Instagram" }
        return "Open \(name)'s profile on Instagram"
    }
}
