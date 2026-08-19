import XCTest

/// #712: a follower band is stored against whatever account string a caption
/// credited, and nothing ever showed which bands those keys still match.
///
/// The analytics run reads `org_bands.get(org, "unknown")`
/// (`postroll/ai/analyze_posts.py`), so a band whose key no post carries is not
/// an error and produces no complaint. It simply never applies: the posts it
/// was entered for are analysed as untagged, while the entry goes on reading as
/// a judgement Dan recorded (L90). The accounts screen listed only accounts the
/// posts credit, so those entries had no row at all and could be neither
/// corrected nor cleared.
final class OrgBandAuditTests: XCTestCase {

    private func audit(posts: [String?],
                       bands: [String: OrgFollowerBand]) -> OrgBandAudit.Audit {
        OrgBandAudit.audit(orgsInPosts: posts, bands: bands)
    }

    // MARK: - What the screen has to show

    func testABandNoPostCreditsIsReportedWithTheBandItHolds() {
        let result = audit(posts: ["kyhs_music", "kyhs_music"],
                           bands: ["kyhs_music": .k1to10, "merkin_hall": .k10to50])

        XCTAssertEqual(result.stranded.map(\.org), ["merkin_hall"],
                       "a band matching no post was not reported")
        XCTAssertEqual(result.stranded.first?.band, .k10to50,
                       "the row has to carry the band it holds, or Dan cannot "
                     + "tell which judgement is stranded")
        XCTAssertEqual(result.stranded.first?.posts, 0)
    }

    func testACreditedAccountWithNoBandIsStillListed() {
        let result = audit(posts: ["kyhs_music"], bands: [:])

        XCTAssertEqual(result.credited.map(\.org), ["kyhs_music"])
        XCTAssertEqual(result.credited.first?.band, .unknown,
                       "an account with nothing stored reads as unknown, which "
                     + "is what the analytics run assumes for it")
        XCTAssertEqual(result.credited.first?.posts, 1)
    }

    func testTheRowCarriesHowManyPostsCreditTheAccount() {
        let result = audit(posts: ["a", "b", "a", "a"], bands: [:])

        XCTAssertEqual(result.credited.map(\.posts), [3, 1],
                       "the count is per account, not the total")
    }

    /// The control this file needs most: if everything were reported stranded,
    /// every assertion above would pass while the screen shouted at a store
    /// with nothing wrong with it (L36, L159).
    func testAStoreWhereEveryBandMatchesReportsNothingStranded() {
        let result = audit(posts: ["a", "b"], bands: ["a": .under1k, "b": .k50plus])

        XCTAssertTrue(result.stranded.isEmpty,
                      "a healthy store was reported as having stranded bands")
        XCTAssertEqual(result.credited.map(\.org), ["a", "b"])
    }

    func testAnAccountIsNeverInBothLists() {
        let result = audit(posts: ["a"], bands: ["a": .under1k, "z": .under1k])

        let all = result.credited.map(\.org) + result.stranded.map(\.org)
        XCTAssertEqual(all.count, Set(all).count, "an account was listed twice")
    }

    // MARK: - Order and counting

    func testBothListsAreAlphabetical() {
        let result = audit(posts: ["zed", "alpha", "mid"],
                           bands: ["zzz_old": .under1k, "aaa_old": .under1k])

        XCTAssertEqual(result.credited.map(\.org), ["alpha", "mid", "zed"])
        XCTAssertEqual(result.stranded.map(\.org), ["aaa_old", "zzz_old"])
    }

    /// The sidebar badge and the rows come from one predicate, or the badge
    /// promises fewer accounts than the screen lists (L16).
    func testTheCountCoversEveryRowTheScreenShows() {
        let result = audit(posts: ["a", "b"], bands: ["a": .under1k, "gone": .k1to10])

        XCTAssertEqual(result.count, result.credited.count + result.stranded.count)
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - Empty

    func testAStoreWithNoPostsAndNoBandsIsEmpty() {
        XCTAssertTrue(audit(posts: [], bands: [:]).isEmpty)
    }

    /// The whole point of the issue, as a case: no imported posts at all, but a
    /// band still stored. Reporting that as empty is what hid these entries,
    /// because the screen would draw its "no credited accounts yet" state over
    /// a judgement that is still in the file.
    func testAStoreWithNoPostsButAStoredBandIsNotEmpty() {
        let result = audit(posts: [], bands: ["merkin_hall": .k10to50])

        XCTAssertFalse(result.isEmpty,
                       "the empty state would have covered a stored band")
        XCTAssertEqual(result.stranded.map(\.org), ["merkin_hall"])
    }

    // MARK: - What is not an account

    func testPostsWithNoCreditedAccountAreNotAnAccount() {
        // `org` is optional and is nil for a caption crediting nobody. It was
        // never a row, and an empty string must not become one either: it would
        // render as a bare "@" that cannot be corrected to anything.
        let result = audit(posts: [nil, "", "real"], bands: [:])

        XCTAssertEqual(result.credited.map(\.org), ["real"])
    }
}
