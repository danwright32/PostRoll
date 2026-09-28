import SwiftUI

/// An existing event's name, organisation, venue and hall (#1448).
///
/// Opened from the event list's Edit Details item, which replaced an inline
/// Rename that could change the name only. Date and shoot type are not here:
/// they decide which week the posts belong to and which templates apply.
///
/// After a save that changed what the graphics print, the sheet stays up and
/// offers Refresh text, which redraws the rendered days from the saved layout
/// and crops, so only the words move.
struct EditEventDetailsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let eventID: UUID
    var previews: PreviewGraphicsManager = .shared

    @State private var name = ""
    @State private var org = ""
    @State private var venue = ""
    @State private var venueContext = ""
    @State private var loaded = false

    /// Set once Save has written, which turns the form into its outcome.
    @State private var saved: EventDetailsSave?
    /// Whether Refresh text has been pressed on this save.
    @State private var refreshStarted = false
    /// Whether Dan stopped it, so a stopped refresh is not read as finished.
    @State private var refreshStopped = false
    /// Why a Refresh text press could not start.
    @State private var refreshRefusal: String?

    private var event: Event? { appState.events.first { $0.id == eventID } }

    private var refusal: String? { NewEventValidation.refusal(name: name) }

    var body: some View {
        ZStack {
            PaintedSurfaces.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Details")
                        .font(.signPainter(32))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    RoseGoldDivider()
                }
                .padding(.top, Spacing.lg)

                if event == nil {
                    // Deleted from under the sheet. Saying so beats a form
                    // whose Save would write nothing.
                    Text("This event no longer exists.")
                        .font(.light(13))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }
                            .buttonStyle(BrandButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                } else if let saved {
                    outcome(saved)
                } else {
                    form
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .frame(width: 440)
        .onAppear(perform: load)
    }

    // MARK: - The form

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            EventDetailsFields(name: $name, org: $org, venue: $venue,
                               venueContext: $venueContext)

            VStack(alignment: .trailing, spacing: Spacing.sm) {
                if let refusal {
                    RefusalNote(message: refusal)
                }
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(refusal != nil)
                        .opacity(refusal == nil ? 1 : 0.4)
                }
            }
        }
    }

    private func load() {
        guard !loaded, let event else { return }
        name = event.name
        org = event.org
        venue = event.venue
        venueContext = event.venueContext
        loaded = true
    }

    private func save() {
        // Live read (#103): the sheet may have been open while a render landed,
        // and saving a copy from when it opened would put the old media back.
        guard refusal == nil, let before = event else { return }
        let after = NewEventForm.edited(before, name: name, org: org, venue: venue,
                                        venueContext: venueContext)
        let outcome = EventDetailsSave(before: before, after: after)
        guard outcome.changed else {
            dismiss()
            return
        }
        appState.updateEvent(after)
        if outcome.refreshDays.isEmpty && !outcome.exportIsStale {
            // Nothing on disk shows the old details, and the list row already
            // shows the new ones.
            dismiss()
            return
        }
        saved = outcome
    }

    // MARK: - After Save

    @ViewBuilder
    private func outcome(_ saved: EventDetailsSave) -> some View {
        let days = SentenceList.of(saved.refreshDays.map(\.displayName))
        let running = !previews.regeneratingDays(eventID)
            .isDisjoint(with: saved.refreshDays)
        let failures = previews.dayFailures(for: eventID)
            .filter { saved.refreshDays.contains($0.day) }

        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Saved.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)

            if !saved.refreshDays.isEmpty {
                if running {
                    LongRunIndicator(
                        label: "Redrawing \(days)\u{2026}",
                        startedAt: saved.refreshDays
                            .compactMap { previews.dayStartedAt($0, for: eventID) }.min(),
                        eventID: eventID,
                        run: .media,
                        onStop: { refreshStopped = previews.stopRedraw(eventID) },
                        isStopping: previews.isStoppingRedraw(eventID))
                } else if refreshStopped {
                    Text("Stopped. \(days) still show the old details.")
                        .font(.light(12))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                } else if refreshStarted && !failures.isEmpty {
                    ForEach(failures, id: \.day) { failure in
                        Text(failure.reason)
                            .font(.light(12))
                            .foregroundStyle(PaintedSurfaces.bodyText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if refreshStarted {
                    Text("\(days) now show the new details.")
                        .font(.light(12))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                } else {
                    Text("\(days) still show the old details.")
                        .font(.light(12))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                }
                if let refreshRefusal {
                    RefusalNote(message: refreshRefusal)
                }
            }

            if saved.exportIsStale {
                Text("The exported folder still has the old text until you export again.")
                    .font(.light(12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if !saved.refreshDays.isEmpty && !running
                    && (!refreshStarted || refreshStopped || !failures.isEmpty) {
                    Button(refreshStarted ? "Try Again" : "Refresh Text") {
                        refresh(saved.refreshDays)
                    }
                    .buttonStyle(BrandOutlineButtonStyle())
                }
                // Closing never stops a refresh: the manager owns it, and the
                // review screen shows each day's progress.
                Button("Done") { dismiss() }
                    .buttonStyle(BrandButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func refresh(_ days: [DayName]) {
        refreshRefusal = nil
        refreshStopped = false
        if previews.startRedraw(days, for: eventID, appState: appState,
                                work: .detailsEdited) {
            refreshStarted = true
        } else {
            refreshRefusal = "This event's graphics are already being redrawn. "
                + "Refresh again once that finishes."
        }
    }
}
