import SwiftUI

struct InsightsOrgsView: View {
    @Environment(AnalyticsStore.self) private var analyticsStore

    /// A write the store refused. Kept here rather than shown as a toast,
    /// because the condition persists: the store stays blocked and every
    /// further edit is refused too.
    @State private var saveNotice: String?
    /// The entry a confirmation is open for. Clearing a band destroys a
    /// judgement Dan made by going and looking at an account, and there is
    /// nothing to recover it from, so it is confirmed first (L9).
    @State private var confirming: OrgBandAudit.Entry?

    var body: some View {
        let audit = analyticsStore.orgBandAudit

        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACCOUNTS CREDITED")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    Text("The first account each caption credits. Set follower size once per account so analytics can control for audience reach.")
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            RoseGoldDivider()

            if let saveNotice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(PaintedSurfaces.iconAccent)
                    Text(saveNotice)
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }

            if audit.isEmpty {
                OrgsEmptyState()
            } else {
                List {
                    ForEach(audit.credited) { entry in
                        row(entry)
                    }

                    if !audit.stranded.isEmpty {
                        Section {
                            ForEach(audit.stranded) { entry in
                                row(entry)
                            }
                        } header: {
                            StrandedHeader(count: audit.stranded.count)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(PaintedSurfaces.page)
            }
        }
        .background(PaintedSurfaces.page)
        .confirmationDialog(
            confirming.map { "Forget the follower band for @\($0.org)?" } ?? "",
            isPresented: Binding(get: { confirming != nil },
                                 set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { entry in
            Button("Forget it", role: .destructive) { clear(entry) }
            Button("Keep it", role: .cancel) { confirming = nil }
        } message: { entry in
            // Derived from the entry rather than asserted, so it says what is
            // actually being thrown away (L180).
            Text("\(entry.band.displayName) followers. Nothing else in PostRoll "
               + "records this, so you would have to look the account up again.")
        }
    }

    private func row(_ entry: OrgBandAudit.Entry) -> some View {
        OrgRow(entry: entry) { newBand in
            saveNotice = InsightsDisplay.unsavedBandNotice(
                save: analyticsStore.setOrgBand(entry.org, newBand),
                org: entry.org, edit: .set)
        } onClear: {
            confirming = entry
        }
        .listRowBackground(Color.cream)
        .listRowInsets(EdgeInsets(top: 4, leading: Spacing.lg, bottom: 4, trailing: Spacing.lg))
        .listRowSeparatorTint(PaintedSurfaces.edgeRule)
    }

    private func clear(_ entry: OrgBandAudit.Entry) {
        saveNotice = InsightsDisplay.unsavedBandNotice(
            save: analyticsStore.clearOrgBand(entry.org),
            org: entry.org, edit: .cleared)
        confirming = nil
    }
}

// MARK: - Stranded section

/// Says what the rows below it are, in one sentence, because a row with a band
/// and no posts looks identical to a healthy one otherwise.
private struct StrandedHeader: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BANDS WITH NO POSTS")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.bodyText)
            Text(count == 1
                 ? "One stored band matches no imported post, so it is not being applied to anything. Set it on the right account above, or forget it."
                 : "\(count) stored bands match no imported post, so they are not being applied to anything. Set them on the right accounts above, or forget them.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .textCase(nil)
        }
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Org row

private struct OrgRow: View {
    let entry: OrgBandAudit.Entry
    let onChange: (OrgFollowerBand) -> Void
    let onClear: () -> Void

    /// Deliberately not `@State` seeded from the entry. The row is identified
    /// by the account, so clearing a band leaves the same row in place with a
    /// new value, and a local copy made once in an initialiser would go on
    /// showing the band that was just forgotten (L14).
    private var selected: Binding<OrgFollowerBand> {
        Binding(get: { entry.band }, set: { onChange($0) })
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(entry.org)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                Text(subtitle)
                    .font(.light(10))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
            Spacer()

            // Only offered where there is something stored to forget, so the
            // control is never a no-op that reads as broken.
            if entry.band != .unknown {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Forget the stored band for @\(entry.org)")
                .accessibilityLabel("Forget the stored follower band for \(entry.org)")
            }

            Picker("Follower band", selection: selected) {
                ForEach(OrgFollowerBand.allCases) { band in
                    Text(band.displayName).tag(band)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)
            .accessibilityLabel("Follower band for \(entry.org)")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch entry.posts {
        case 0: return "No imported posts credit this account"
        case 1: return "Instagram followers, 1 post"
        default: return "Instagram followers, \(entry.posts) posts"
        }
    }
}

// MARK: - Empty state

private struct OrgsEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "at")
                .font(.system(size: 28))
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Text("No credited accounts yet.")
                .font(.light(13))
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Text("Import your Meta CSV first. These are read from the @-mentions in your captions.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaintedSurfaces.page)
    }
}
