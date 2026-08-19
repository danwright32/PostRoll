import SwiftUI

struct InsightsOrgsView: View {
    @Environment(AnalyticsStore.self) private var analyticsStore

    var body: some View {
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

            if analyticsStore.uniqueOrgs.isEmpty {
                OrgsEmptyState()
            } else {
                List {
                    ForEach(analyticsStore.uniqueOrgs, id: \.self) { org in
                        OrgRow(
                            org: org,
                            band: analyticsStore.orgFollowerBands[org] ?? .unknown
                        ) { newBand in
                            analyticsStore.setOrgBand(org, newBand)
                        }
                        .listRowBackground(Color.cream)
                        .listRowInsets(EdgeInsets(top: 4, leading: Spacing.lg, bottom: 4, trailing: Spacing.lg))
                        .listRowSeparatorTint(PaintedSurfaces.edgeRule)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(PaintedSurfaces.page)
            }
        }
        .background(PaintedSurfaces.page)
    }
}

// MARK: - Org row

private struct OrgRow: View {
    let org: String
    let band: OrgFollowerBand
    let onChange: (OrgFollowerBand) -> Void

    @State private var selected: OrgFollowerBand

    init(org: String, band: OrgFollowerBand, onChange: @escaping (OrgFollowerBand) -> Void) {
        self.org = org
        self.band = band
        self.onChange = onChange
        _selected = State(initialValue: band)
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(org)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                Text("Instagram followers")
                    .font(.light(10))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
            Spacer()
            Picker("Follower band", selection: $selected) {
                ForEach(OrgFollowerBand.allCases) { band in
                    Text(band.displayName).tag(band)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)
            .onChange(of: selected) { _, new in onChange(new) }
        }
        .padding(.vertical, 4)
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
