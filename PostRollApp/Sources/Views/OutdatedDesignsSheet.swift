import SwiftUI

/// Every day whose cached assets predate the current design, in one place (#293).
///
/// The caption review screen badges the day it is showing, which is only
/// visible on the day you happen to open. There are 66 day folders across 12
/// events on disk, so after a design version is bumped there was no way to find
/// which days it dated short of visiting every day of every event. The
/// mechanism only pays off at the moment a design changes, and that is exactly
/// the moment it was least usable.
///
/// The scan lists directories, so it runs when the sheet opens and when Dan
/// asks for it again, never from `body`.
struct OutdatedDesignsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [OutdatedDesignsGroup] = []
    /// Days that are behind the design AND have already been exported (#925).
    ///
    /// Their own list rather than rows mixed into the one above, because the
    /// list above exists to point at work worth doing and rebuilding a day
    /// whose files have gone out changes nothing anyone will see. Kept on
    /// screen rather than dropped: they are still behind the design, and a
    /// surface that hid them would claim a cleaner machine than it measured
    /// (L98).
    @State private var exportedGroups: [OutdatedDesignsGroup] = []
    @State private var result = DesignScanResult(stale: [], daysWithAssets: 0, daysWithARecord: 0)
    @State private var hasPreviewRoot = true
    /// Three states, told apart: never scanned, scanning, and a finished scan.
    /// A spinner that looks the same whether the work is running or dead is a
    /// defect, and this one walks a directory tree per event.
    @State private var isScanning = false
    @State private var scannedAt: Date?

    var body: some View {
        ZStack {
            PaintedSurfaces.page.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking at every rendered day…")
                            .font(.light(12))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    }
                } else if groups.isEmpty && exportedGroups.isEmpty {
                    Text(OutdatedDesignsDisplay.summary(result,
                                                        hasPreviewRoot: hasPreviewRoot))
                        .font(.system(size: 13))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            ForEach(groups) { group in
                                eventSection(group)
                            }
                            if !exportedGroups.isEmpty {
                                alreadyExported
                            }
                        }
                        .padding(.bottom, Spacing.md)
                    }
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(Spacing.xl)
        }
        .frame(width: 520, height: 460)
        .task { await rescan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Outdated Designs")
                .font(.signPainter(30))
                .foregroundStyle(PaintedSurfaces.bodyText)
            RoseGoldDivider()
            if !isScanning {
                Text(OutdatedDesignsDisplay.summary(result,
                                                    hasPreviewRoot: hasPreviewRoot))
                    .font(.light(12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .padding(.top, 2)
            }
        }
    }

    private func eventSection(_ group: OutdatedDesignsGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BrandSectionLabel(group.title)
            ForEach(group.days) { day in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(OutdatedDesignsDisplay.rowLabel(day))
                        .font(.system(size: 13))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let id = group.eventID {
                        Button("Open day") { open(eventID: id) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    } else {
                        // Named rather than hidden: the files are on disk, and a
                        // row that vanished would make this surface claim a
                        // clean machine. There is nothing to regenerate them
                        // from, so there is nothing to offer either.
                        Text("no event on record")
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    }
                }
                .padding(.vertical, 4)
                PaintedSurfaces.edgeRule.frame(height: 0.5)
            }
        }
    }

    /// The days that have already gone out, below everything worth acting on
    /// and introduced by a line saying why they are set apart.
    private var alreadyExported: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            RoseGoldDivider()
            Text("Already exported")
                .font(.signPainter(20))
                .foregroundStyle(PaintedSurfaces.bodyText)
            Text("These are behind the current design too, but their files have "
                 + "already gone out, so rebuilding them would not change anything "
                 + "anyone has seen.")
                .font(.light(12))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(exportedGroups) { group in
                eventSection(group)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let scannedAt, !isScanning {
                Text("Checked \(scannedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.light(11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
            Spacer()
            Button("Check again") { Task { await rescan() } }
                .buttonStyle(.link)
                .disabled(isScanning)
            Button("Done") { dismiss() }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Take Dan to the day. The regeneration itself lives on the caption review
    /// screen, which owns the run, the progress and the result, so this hands
    /// him to the button that already works rather than starting a second way of
    /// doing the same thing.
    private func open(eventID: Event.ID) {
        if let updated = EventStageTransition.applying(.assetsGenerated,
                                                       toEventWithID: eventID,
                                                       in: appState.events) {
            appState.updateEvent(updated)
        }
        appState.sidebarMode = .events
        appState.selectedEventID = eventID
        dismiss()
    }

    private func rescan() async {
        isScanning = true
        let root = AppPaths.previewDir
        let found = await Task.detached { () -> (DesignScanResult, Bool) in
            (DesignStaleScan.scan(previewRoot: root),
             DesignStaleScan.hasPreviewRoot(root))
        }.value
        groups = OutdatedDesignsDisplay.groups(found.0.staleNotExported,
                                               events: appState.events)
        exportedGroups = OutdatedDesignsDisplay.groups(found.0.staleExported,
                                                       events: appState.events)
        result = found.0
        hasPreviewRoot = found.1
        scannedAt = Date()
        isScanning = false
    }
}
