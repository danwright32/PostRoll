import SwiftUI

/// The collaborator suggestion for one day, on the screen where Dan reviews
/// that day's tags (#278).
///
/// A tag puts someone in the "tagged people" list, which almost nobody sees. A
/// collaborator invite puts the post on that account's own grid and in front of
/// their followers, so it is the single biggest reach lever in the week's
/// output, and Instagram allows only five per post.
///
/// Every name carries the reason it is there: the figures it was ranked on and
/// whether it is in the first photo. An ordered list with no reasons is not
/// something anyone can disagree with, and disagreeing is the point, since the
/// swap is Dan's call.
struct CollaboratorPanel: View {
    let result: CollaboratorPick.Result
    /// How many separate events have tagged each account, keyed the way the
    /// book keys (#289). Decides which rows are worth asking numbers for.
    /// Passed in rather than derived here, because it walks every event and
    /// `body` runs on every redraw (L91).
    var eventCounts: [String: Int] = [:]
    /// Open the numbers form for one account. The whole ranking runs on figures
    /// Dan enters, so the way to enter them is beside the names being ranked.
    let onEditNumbers: (String) -> Void
    /// A later photo worth leading with, and the press that does it (#983).
    /// Nil when the photo in front already leads, or the day has no first photo
    /// to improve. ONE parameter rather than three: this view is built inside
    /// `CaptionReviewView`'s body, which is at the type checker's limit.
    var lead: PhotoLead?

    /// Everything the reorder suggestion needs, in one value.
    struct PhotoLead {
        let promotion: CollaboratorPick.PhotoPromotion
        /// Whether this day actually has a cell layout or crops to lose, read
        /// off the day rather than assumed, so the warning is not boilerplate.
        let dropsLayout: Bool
        let promote: () -> Void
    }

    /// What this day's answer is, in a sentence (#964, #1115).
    ///
    /// The four answers used to be two: a ranking, or nothing at all. Nothing
    /// at all covered both "everyone tagged should be invited" and "nobody is
    /// tagged yet", which are opposite things to tell somebody.
    ///
    /// Every word of it comes from `CollaboratorPick`, so this screen and
    /// CAPTIONS.txt cannot come to describe one day differently. Two of the
    /// four were typed in here until #1115, which is the drift a shared
    /// wording exists to prevent, and `CollaboratorPickTests` holds this file
    /// to it rather than trusting the habit.
    private var subtitle: String { CollaboratorPick.panelSubtitle(for: result) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("COLLABORATORS TO INVITE")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(result.suggested.enumerated()), id: \.element.handle) { index, candidate in
                // Numbered only where the order was decided. A numbered list is
                // a ranking however the sentence above it is worded, and under
                // `.allFit` nobody was ranked and nobody was cut (#964).
                row(rank: result.coverage == .ranked ? "\(index + 1)." : "",
                    candidate: candidate)
            }

            if let excluded = result.strongestExcluded {
                // Without this line the exclusion is invisible: an account with
                // ten times anyone's reach would silently never be offered, and
                // nothing on screen would say why.
                divider
                Text(result.membership.leftOutHeading)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Text("Swap in by hand if the reach is worth it.")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                row(rank: "", candidate: excluded)
            }

            // Two different states, two headings (#982). One heading over both
            // put a private account, which nobody can ever count, under a
            // claim that somebody has not counted it yet, contradicting the
            // row directly beneath it. The split is shared with the caption
            // block rather than filtered again here.
            let unranked = CollaboratorPick.splitUnranked(result.unranked)

            if !unranked.waiting.isEmpty {
                divider
                Text("NOT COUNTED YET, SO NOT RANKED")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                ForEach(unranked.waiting, id: \.handle) { candidate in
                    row(rank: "", candidate: candidate)
                }
            }

            if !unranked.marked.isEmpty {
                divider
                Text("PRIVATE, SO NOT RANKED")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Text(CollaboratorPick.privateFormNote)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unranked.marked, id: \.handle) { candidate in
                    row(rank: "", candidate: candidate)
                }
            }

            if !result.excluded.isEmpty, result.coverage != .allHeldBack {
                divider
                Text("MARKED NEVER TO INVITE")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                ForEach(result.excluded, id: \.handle) { candidate in
                    row(rank: "", candidate: candidate)
                }
            }

            // Offered rather than described (#983). On a carousel only the
            // first photo appears in the feed, so a post whose strongest
            // accounts sit further along credits nobody who can usefully
            // collaborate, and the fix is one press. A finding the app could
            // apply itself, handed back as a sentence, teaches Dan to skim the
            // panel where the findings that need his judgement live (L272).
            if let lead {
                divider
                Text("A STRONGER PHOTO COULD LEAD")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Text(CollaboratorPick.promotionReason(lead.promotion))
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Button(CollaboratorPick.promotionControlLabel(for: lead.promotion),
                           action: lead.promote)
                    Text(CollaboratorPick.promotionCostLine(dropsLayout: lead.dropsLayout))
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(result.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(PaintedSurfaces.deepPage)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
                )
        )
    }

    private var divider: some View {
        RoseGoldDivider(opacity: 0.3).padding(.vertical, 2)
    }

    private func row(rank: String, candidate: CollaboratorPick.Candidate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !rank.isEmpty {
                Text(rank)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .frame(width: 16, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 1) {
                // A link to the profile, because the next thing Dan does with
                // a name here is open it to read the numbers off (#973). The
                // panel holds no checked URL for a candidate, only the handle,
                // so the address is built from it.
                ProfileHandleText(handle: candidate.handle)
                Text(candidate.reason)
                    .font(.system(size: 10))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // Only on the few that come back, so the row says why it is the
                // one worth a minute (#289).
                if let note = RecurringAccounts.recurrenceNote(
                        handle: candidate.handle, in: eventCounts) {
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                }
            }
            Spacer()
            // The one step way to fix a number in place (#280). Beside the
            // figure it corrects, so a stale count is fixed where it is read
            // rather than on some other screen.
            //
            // Quieter on an account tagged once and never again (#289): the ask
            // is still there, it just stops competing with the handful whose
            // numbers the ranking actually leans on. Measured on the real
            // events: 32 of 38 accounts are one-offs.
            Button(candidate.stats?.hasEngagementData == true ? "Update" : "Add numbers") {
                onEditNumbers(candidate.handle)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(
                RecurringAccounts.emphasis(handle: candidate.handle, in: eventCounts) == .prominent
                    ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
            .accessibilityLabel("Edit numbers for \(candidate.handle)")
        }
    }
}

/// Enter or correct one account's follower and engagement numbers (#279, #280).
///
/// The only source that works without a platform API is Dan entering them, and
/// that is only worth doing if the app keeps them: a performer tagged in March
/// should already be scored the next time they turn up.
struct AccountNumbersSheet: View {
    let handle: String
    let stats: AccountStats?
    /// Followers, likes, comments, whether the profile is private, and whether
    /// Dan will never invite it. Any of the three figures may be nil, which
    /// stores as "not counted" rather than zero. Both marks are always stated,
    /// because this form is the only thing that can set or clear either.
    let onSave: (Int?, Int?, Int?, Bool, Bool) -> Void
    let onCancel: () -> Void

    @State private var followers: String = ""
    @State private var likes: String = ""
    @State private var comments: String = ""
    @State private var isPrivate: Bool = false
    @State private var neverInvite: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // The screen that TELLS him to open the profile is the one that
            // most needs to be able to (#973).
            ProfileHandleText(handle: handle,
                              font: .system(size: 16, weight: .semibold))

            // The requirement BEFORE the fields, not after the save (#977).
            // Drawn from the record rather than spelled here, so this sentence
            // and the label a row shows cannot come to disagree about the rule.
            Text("Open their profile and read these off a few recent posts. "
                 + AccountStats.numbersFormRequirement)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            field("Followers", text: $followers)
            field("Likes on a typical post", text: $likes)
            field("Comments on a typical post", text: $comments)

            // Here rather than anywhere else because this is where Dan is
            // standing when he finds out: the form has just told him to open
            // the profile, and a private one answers with a follower count and
            // nothing else (#982). Nothing can detect it from the logged out
            // page, so this control is the only way the mark is ever made.
            Toggle("Private account", isOn: $isPrivate)
                .font(.system(size: 12))
            Text(CollaboratorPick.privateFormNote)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // A standing decision rather than a figure (#1271). Here beside the
            // private mark because both are facts about the account that only
            // Dan can record, and this is the one form that records them.
            Toggle("Never invite as a collaborator", isOn: $neverInvite)
                .font(.system(size: 12))
            Text(CollaboratorPick.neverInviteFormNote)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // The date is shown wherever the numbers are (#280), so a figure
            // driving a ranking cannot look equally confident whether it was
            // entered last week or two years ago.
            if let stats, stats.recordedOn != nil {
                Text(stats.freshnessLabel(asOf: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(stats.freshness(asOf: Date()).isStale
                                     ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Button("Save") {
                    onSave(AccountNumbersEntry.parse(followers),
                           AccountNumbersEntry.parse(likes),
                           AccountNumbersEntry.parse(comments),
                           isPrivate, neverInvite)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 360)
        .onAppear {
            // Prefilled from what is stored, so saving without touching a field
            // cannot silently clear it.
            followers = AccountNumbersEntry.text(stats?.followers)
            likes = AccountNumbersEntry.text(stats?.likes)
            comments = AccountNumbersEntry.text(stats?.comments)
            // Prefilled like every other field, so saving an unrelated
            // correction cannot silently unmark the account.
            isPrivate = stats?.isPrivate ?? false
            neverInvite = stats?.neverInvite ?? false
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.secondaryText)
            TextField("Not counted", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}
