import XCTest

/// Insights names the thing it actually measures (#706).
///
/// The section listed accounts and called them organizations. The value it
/// groups by is not the event's organization at all: it is the first @account
/// the caption mentions, whichever account that happens to be
/// (`postroll/ai/import_meta_csv.py`, `_extract_org`).
///
/// The two were the same string for as long as every caption led with the
/// company's handle, which is why this stayed invisible. #689 made the
/// organization optional, so a shoot with no company now leads with the venue
/// or a performer, and that account appeared in the list as an organization
/// with a follower size set against it. The follower size exists to control for
/// audience reach when comparing posts, so a wrong one is not cosmetic.
///
/// Dan's call: keep the value, which is genuinely useful (whose audience did
/// this post reach through), and stop calling it something it is not.
///
/// These read the screens' own source, because what is wrong is the words on
/// them. Nothing about the stored data changes, so no behavioural test could
/// see this.
final class InsightsCreditedAccountCopyTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/Insights/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every screen a person reads this on. A rename that reached one of them
    /// and not the others would leave the product contradicting itself, which
    /// is worse than the original wrong word: each sentence reads correctly
    /// alone and only the pair is wrong (L118).
    private let screens = ["InsightsSidebarView.swift",
                           "InsightsOrgsView.swift",
                           "InsightsPostsView.swift"]

    /// What a person sees, with the code's own comments taken out: prose
    /// explaining the old name must not satisfy a check for the new one (L103).
    private func shownWords(in name: String) throws -> String {
        try source(name)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            .joined(separator: "\n")
    }

    func testNoInsightsScreenCallsTheseAccountsAnOrganization() throws {
        for screen in screens {
            let words = try shownWords(in: screen)
            for line in words.split(separator: "\n") where line.contains("\"") {
                let lower = line.lowercased()
                guard lower.contains("organi") || lower.range(of: #""orgs?""#,
                                                              options: .regularExpression) != nil
                else { continue }
                XCTFail("\(screen) still shows the word organisation to Dan, on a "
                        + "value that is whichever account the caption credited "
                        + "first: \(line)")
            }
        }
    }

    func testTheSectionSaysWhatTheValueIs() throws {
        let sidebar = try shownWords(in: "InsightsSidebarView.swift")
        XCTAssertTrue(sidebar.lowercased().contains("credited"),
                      "the section is not named after what it holds: \(sidebar)")
    }

    func testTheFollowerSizeSentenceIsAboutAnAccount() throws {
        // The sentence that does the damage: it is the instruction to set a
        // follower size, and it told Dan he was setting one per organisation.
        let orgs = try shownWords(in: "InsightsOrgsView.swift")
        XCTAssertTrue(orgs.contains("once per account"),
                      "the follower size instruction still names the wrong unit")
    }

    func testTheEmptyStateSaysWhereTheseComeFrom() throws {
        // The one place that already told the truth, and it must keep telling
        // it: these are pulled out of the captions, not typed on the event.
        let orgs = try shownWords(in: "InsightsOrgsView.swift")
        XCTAssertTrue(orgs.contains("captions"),
                      "nothing tells Dan these are read out of his captions, "
                      + "which is the fact that makes the list make sense")
    }
}
