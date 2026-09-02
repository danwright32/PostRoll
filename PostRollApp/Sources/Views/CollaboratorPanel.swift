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
                Text("LEFT OUT ONLY FOR NOT BEING IN THE FIRST PHOTO")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Text("Swap in by hand if the reach is worth it.")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                row(rank: "", candidate: excluded)
            }

            if !result.unranked.isEmpty {
                divider
                Text("NOT COUNTED YET, SO NOT RANKED")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                ForEach(result.unranked, id: \.handle) { candidate in
                    row(rank: "", candidate: candidate)
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
    /// Followers, likes, comments. Any of them may be nil, which stores as
    /// "not counted" rather than zero.
    let onSave: (Int?, Int?, Int?) -> Void
    let onCancel: () -> Void

    @State private var followers: String = ""
    @State private var likes: String = ""
    @State private var comments: String = ""

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
                           AccountNumbersEntry.parse(comments))
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
