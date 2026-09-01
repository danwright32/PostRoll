import SwiftUI

/// What the app changed in this post, on the panel rather than in a terminal
/// (#1162).
///
/// Repairs are silent by design, so the journal is the only record that the app
/// rewrote anything. Until this existed the only way to read it was
/// `tools/read_repair_log.py`, and Dan does not work in a terminal, so in
/// practice the evidence did not exist for him (L46).
///
/// Collapsed by default. Rule 1 makes repairs silent, and a panel that unfolded
/// a list of rewrites on every post would put the thing back that silence was
/// chosen to remove. The disclosure says whether there is anything to see, so
/// opening it is a decision rather than a search.
struct RepairRecordView: View {
    /// Which post to read the journal for.
    let eventID: UUID
    /// Whether any run that can write to the journal is going, so the read is
    /// redone when one finishes and not on every redraw.
    let runsActive: Bool
    /// A journal other than the app's own, for a preview or a test.
    var journal: URL? = nil

    @State private var isOpen = false
    /// nil until it has been read. "Nobody has looked" and "looked and found
    /// nothing" are different, and showing the second before the first has
    /// happened would be an empty state nothing measured (L98).
    @State private var loaded: RepairJournal.Reading? = nil

    private var reading: RepairJournal.Reading { loaded ?? .nothingRecorded }

    /// What the read is keyed on. Its own Equatable type rather than an
    /// interpolated string, so the key costs the type checker nothing.
    private struct Key: Equatable {
        let eventID: UUID
        let runsActive: Bool
    }

    private var key: Key { Key(eventID: eventID, runsActive: runsActive) }

    private var records: [RepairJournal.Record] {
        if case .records(let records) = reading { return records }
        return []
    }

    /// The one state that is worth saying without being asked. "Nothing
    /// recorded" is the normal case and stays behind the disclosure; a record
    /// that is THERE and cannot be read is a fault, and hiding it would leave
    /// the panel silently claiming less than it knows (L10, L11).
    private var isFault: Bool {
        if case .unreadable = reading { return true }
        return false
    }

    var body: some View {
        content
            // Reading the journal touches the filesystem, so it happens here,
            // keyed, rather than in a body that runs on every redraw (L91).
            .task(id: key) {
                loaded = RepairJournal.reading(forEventID: eventID, at: journal)
            }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("What the app changed here")
                        .font(.system(size: 11, weight: .medium))
                    if !records.isEmpty {
                        Text("(\(records.count))")
                            .font(.light(11))
                    }
                }
                .foregroundStyle(isFault
                                 ? PaintedSurfaces.pageAccentText
                                 : PaintedSurfaces.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(loaded == nil)
            .accessibilityLabel("What the app changed in this post")
            .accessibilityHint(isOpen ? "Hides the list" : "Shows the list")

            if isOpen || isFault {
                Text(RepairRecordPanelText.summary(for: reading))
                    .font(.light(11))
                    .foregroundStyle(isFault
                                     ? PaintedSurfaces.pageAccentText
                                     : PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isOpen {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(RepairRecordPanelText.lines(for: record)
                            .enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, Spacing.sm)
                }
            }
        }
    }
}
