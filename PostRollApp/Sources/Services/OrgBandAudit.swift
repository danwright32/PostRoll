import Foundation

/// What the accounts screen lists: every account that either an imported post
/// credits or a stored follower band names, and which of the two named it.
///
/// A band is keyed by the account string a caption credited, so a key can stop
/// matching anything: the first credited account is the venue or a performer
/// rather than the presenter (#706), an account renames, or the band was
/// entered against the wrong one of the three in the first place. The analytics
/// run reads `org_bands.get(org, "unknown")` in
/// `postroll/ai/analyze_posts.py`, so a band nothing matches is not an error
/// and produces no complaint: it simply never applies. The posts it was meant
/// for are analysed as untagged, and the entry goes on reading as a judgement
/// that was recorded (L90).
///
/// Nothing here removes an entry, and nothing calling it may remove one on its
/// own. A band is a judgement Dan made by going and looking at an account; it
/// cannot be recovered from the data, and a rule about what should be SHOWN is
/// never a reason to delete what it filters (L116, #712).
enum OrgBandAudit {

    struct Entry: Equatable, Identifiable {
        let org: String
        let band: OrgFollowerBand
        /// How many imported posts credit this account. Zero is what makes an
        /// entry stranded, and it is shown rather than implied, because it is
        /// the whole reason the row is being pointed at.
        let posts: Int

        var id: String { org }
    }

    struct Audit: Equatable {
        /// Accounts the imported posts credit, alphabetically.
        let credited: [Entry]
        /// Accounts only a stored band names. No imported post carries them, so
        /// the band is currently applied to nothing.
        let stranded: [Entry]

        var isEmpty: Bool { credited.isEmpty && stranded.isEmpty }

        /// What the sidebar badge counts. The badge and the rows come from one
        /// predicate, or the badge promises fewer accounts than the screen
        /// lists and the stranded ones are hidden a second way (L16).
        var count: Int { credited.count + stranded.count }
    }

    static func audit(orgsInPosts: [String?],
                      bands: [String: OrgFollowerBand]) -> Audit {
        var counts: [String: Int] = [:]
        for case let org? in orgsInPosts where !org.isEmpty {
            counts[org, default: 0] += 1
        }

        let credited = counts.keys.sorted().map {
            Entry(org: $0, band: bands[$0] ?? .unknown, posts: counts[$0] ?? 0)
        }
        let stranded = bands.keys.filter { counts[$0] == nil }.sorted().map {
            Entry(org: $0, band: bands[$0] ?? .unknown, posts: 0)
        }
        return Audit(credited: credited, stranded: stranded)
    }
}
