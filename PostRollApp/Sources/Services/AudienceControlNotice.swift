import Foundation

/// What a report says about how much of it could not be controlled for
/// audience size (#720).
///
/// Posts whose credited account has no follower band are analysed as
/// uncontrolled observations rather than compared within a follower tier. That
/// is the right treatment, and #712 made the stored bands visible and
/// correctable, which is the input side. This is the output side: the finished
/// report read exactly the same whether that applied to two posts or two
/// hundred, so a thin report could not be recognised as thin and was trusted as
/// though every comparison were fair.
///
/// Pure, so each case can be stated and asserted without a screen behind it
/// (L151).
enum AudienceControlNotice {

    /// Which of the states this is. Kept apart rather than folded into "is
    /// there a problem", because a report nobody measured and a report where
    /// every comparison was controlled are opposite facts that would otherwise
    /// render identically (L10, L90).
    enum Kind: Equatable {
        /// Every analysed post was compared within its follower tier.
        case allControlled
        /// Some were not, and the notice says how many out of how many.
        case someUncontrolled
        /// Generated before this was recorded, or carrying numbers that cannot
        /// be true. Either way nothing here may claim a figure.
        case notMeasured
    }

    struct Notice: Equatable {
        var kind: Kind
        var headline: String
        /// The second sentence, when there is more to explain than the count.
        var detail: String?
        /// The credited accounts with no band, so the notice names what would
        /// fix it rather than only that something is wrong (L80).
        var accounts: [String]
        /// Whether to offer the accounts screen. False when nothing there could
        /// change the state being reported: a control that cannot alter what it
        /// is offered for is a dead control (L111).
        var showsAccountsLink: Bool
    }

    /// What to show under `report`, or nil when there is nothing worth saying.
    static func forReport(_ report: InsightReport) -> Notice? {
        guard let analyzed = report.analyzedCount,
              let uncontrolled = report.uncontrolledCount else {
            return Notice(kind: .notMeasured, headline: notMeasuredText,
                          detail: nil, accounts: [], showsAccountsLink: false)
        }
        // A count larger than the population it is out of cannot be true, and
        // showing it would read as a defect in the report rather than in
        // whatever produced the number.
        guard uncontrolled <= analyzed else {
            return Notice(kind: .notMeasured, headline: notMeasuredText,
                          detail: nil, accounts: [], showsAccountsLink: false)
        }
        // Zero of zero posts is true and useless, and a tick over it says the
        // report is sound when there is no report.
        guard analyzed > 0 else { return nil }

        guard uncontrolled > 0 else {
            return Notice(
                kind: .allControlled,
                headline: "Every one of the \(analyzed) posts in this report was "
                        + "compared within its own follower tier.",
                detail: nil, accounts: [], showsAccountsLink: false)
        }

        let accounts = report.uncontrolledOrgs
        let uncredited = report.uncreditedCount ?? 0
        // The denominator is not decoration. Twelve is most of a fifteen post
        // report and a rounding error in a four hundred post one, and telling
        // those apart is the whole point.
        let headline = "\(uncontrolled) of the \(analyzed) posts in this report "
                     + "could not be compared for audience size."

        var parts: [String] = []
        if !accounts.isEmpty {
            parts.append("\(accounts.count == 1 ? "One account has" : "\(accounts.count) accounts have") "
                         + "no follower band set, so their posts were treated as "
                         + "uncontrolled observations.")
        }
        if uncredited > 0 {
            // Named as its own cause, because setting a band cannot fix it and
            // a reader sent to the accounts screen for these would find nothing
            // to do there (L11, L111).
            parts.append("\(uncredited) credited no account at all, so there is "
                         + "no band to set for them.")
        }

        return Notice(kind: .someUncontrolled, headline: headline,
                      detail: parts.isEmpty ? nil : parts.joined(separator: " "),
                      accounts: accounts,
                      showsAccountsLink: !accounts.isEmpty)
    }

    /// Says that nothing was measured, without claiming a figure.
    ///
    /// A missing measurement rendered as zero is indistinguishable from a
    /// report where every comparison was controlled (L90), so this states the
    /// absence instead.
    static let notMeasuredText =
        "This report was generated before PostRoll recorded how much of a "
        + "report can be compared within a follower tier, so there is no way to "
        + "tell. Generate a new one to find out."
}
