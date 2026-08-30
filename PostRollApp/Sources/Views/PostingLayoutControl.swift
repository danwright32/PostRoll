import SwiftUI

/// The per event posting layout picker, its sentence, and its confirmation, in
/// one place used by every screen that shows the layout's effect (#1007).
///
/// It lived only on the Export screen. The caption review screen showed the
/// result of the layout and could not change it, and the photos screen printed
/// "Collage uses the first 4 photos (7 assigned)" while offering no way to act
/// on it, which is the screen where that fact is discovered.
struct PostingLayoutControl: View {
    let event: Event

    /// Where the app wide default is read from, INJECTED rather than reached
    /// for.
    ///
    /// This control is now rendered by three screens that are all in the test
    /// bundle, and `AppPreferences.store` is Dan's real preferences: a test
    /// drawing any of them would read his posting layout, and a rendered
    /// control could write it back. That is the hazard #727 recorded, and the
    /// reason `Event.effectivePostingPreset(in:)` already takes a store (L2).
    let defaults: UserDefaults

    /// In memory, and injected with a `.shared` default, which is the shape
    /// `ExportView` and `CaptionReviewView` already use for it.
    ///
    /// NOT `@Environment`: `withAppOwners` does not provide this manager, so
    /// reaching for it CRASHED every screen in the window size sweep rather
    /// than failing an assertion. That file's own comment records the same trap
    /// from #718: a missing environment value is not a red test, it is a dead
    /// process, and the screen never gets to say what was wrong.
    var previews: PreviewGraphicsManager = .shared

    @Environment(AppState.self) private var appState
    @Environment(GenerationManager.self) private var genManager

    @State private var pending: PostingPreset? = nil

    /// Read live from AppState so it reflects the latest write, not the copy
    /// this view was handed.
    private var live: Event {
        appState.events.first(where: { $0.id == event.id }) ?? event
    }

    private var effectivePreset: PostingPreset {
        live.effectivePostingPreset(in: defaults)
    }

    /// Busy means ANY work that writes this event's media, not a full run
    /// alone.
    ///
    /// A layout switch starts one of those, so a control that stayed live
    /// during a per day rebuild would let a second writer start over the first.
    /// `isBusy` is the manager's own answer to that question (#1009).
    private var isBusy: Bool {
        genManager.isRunning(event.id) || previews.state.isBusy(event.id)
    }

    /// Days whose images were drawn under a layout this event has moved past,
    /// through the same predicate the export gate refuses on, so the sentence
    /// here and the refusal there cannot disagree (L263).
    private var staleDays: [DayName] {
        PostingLayoutSwitch.staleDays(in: live, preset: effectivePreset)
    }

    /// Redraw exactly those days, images only.
    ///
    /// Nothing is written first: the layout is already what Dan chose, and the
    /// only thing that failed was the drawing. A refused claim leaves the
    /// sentence and the button exactly where they were, which is the honest
    /// state, because nothing was rebuilt.
    private func redrawStale() {
        let days = staleDays
        guard !days.isEmpty else { return }
        _ = previews.startRedraw(days, for: event.id, appState: appState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
                Text("Posting layout")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                Picker("Posting layout", selection: Binding(
                    get: { effectivePreset },
                    set: { request($0) }
                )) {
                    ForEach(PostingPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 480 rather than 360 since #900: three segments carry their
                // counts in the label ("Opening (7·4·4)"), and a segmented
                // control truncates rather than wrapping, so the numbers that
                // make the labels worth reading are the first thing to go. It
                // is a maximum, so a narrower window still takes less.
                .frame(maxWidth: 480)
                .disabled(isBusy)
            }
            if isBusy {
                // Deliberately NO spinner here, only the reason the control is
                // disabled.
                //
                // Every screen this sits on already draws the rebuild's own
                // progress, with elapsed time and an estimate. A second spinner
                // stacked above it says the same thing with less information,
                // and two indicators for one piece of work is the indistinct
                // display #135 exists to prevent. The first version of this had
                // one and it was caught by rendering the screen, not by any
                // test: the render tests are excluded from the ordinary suite.
                Text("Rebuilding, so the layout cannot change yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            } else {
                Text(PostingLayoutCopy.thisEvent(effectivePreset))
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                // A day the switch never finished redrawing, said HERE (#1010).
                //
                // The export refuses such a day, and its reason is on the export
                // screen; this is the screen showing the layout that day
                // disagrees with. The remedy is a control rather than a
                // sentence, because the condition persists in the event and
                // every other route to it is closed: re-picking the layout
                // already selected fires no change at all.
                if let left = PostingLayoutCopy.stale(staleDays),
                   let redraw = PostingLayoutCopy.redrawAction(staleDays) {
                    HStack(spacing: Spacing.sm) {
                        Text(left)
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.stateWarningText)
                        Button(redraw) { redrawStale() }
                            .font(.system(size: 12))
                    }
                }
            }
        }
        .alert("Change the posting layout?",
               isPresented: Binding(get: { pending != nil },
                                    set: { if !$0 { pending = nil } })) {
            Button("Change", role: .destructive) {
                if let pending { apply(pending) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending.flatMap {
                PostingLayoutSwitch.confirmation(from: effectivePreset, to: $0, in: live)
            } ?? "")
        }
    }

    /// Confirm only when there is something to lose. A switch on an event with
    /// no photos rebuilds nothing, so it applies straight away rather than
    /// asking a question with no consequence behind it.
    private func request(_ newValue: PostingPreset) {
        let ev = live
        guard newValue != ev.effectivePostingPreset(in: defaults) else { return }
        if PostingLayoutSwitch.confirmation(from: ev.effectivePostingPreset(in: defaults),
                                            to: newValue, in: ev) == nil {
            apply(newValue)
        } else {
            pending = newValue
        }
    }

    /// Set this event's override and touch only the days that actually change.
    private func apply(_ newValue: PostingPreset) {
        var ev = live
        let old = ev.effectivePostingPreset(in: defaults)
        guard newValue != old else { return }

        // Only the days this switch actually changes, and split by what each
        // one costs (#1010). Before this, every governed day with photos went
        // to the caption generator: Balanced to Opening moves Sunday from 4
        // photos to 7 and leaves Monday and Wednesday alone, yet all three were
        // regenerated. Two paid API calls that changed no output, and any
        // caption Dan had typed on those days replaced.
        let work = PostingLayoutSwitch.work(
            PostingLayoutSwitch.plan(from: old, to: newValue, in: ev))

        // Claimed BEFORE the event is touched, so a refusal leaves nothing to
        // undo. Mutating first and claiming second means a busy day leaves the
        // layout changed with its previews deleted and no run to replace them
        // (L197, L5).
        var claimedRedraw = false
        if !work.redrawDays.isEmpty {
            claimedRedraw = previews.startRedraw(work.redrawDays, for: event.id,
                                                 appState: appState)
            guard claimedRedraw else { return }
        }

        ev.postingPresetOverride = newValue
        // Cleared only for the days being REBUILT. A day only being redrawn
        // keeps its current image until the new one lands, so a failed redraw
        // leaves the previous graphic rather than nothing at all.
        for day in work.rebuildDays { ev.previewMediaPaths.removeValue(forKey: day) }
        appState.updateEvent(ev)

        if !work.rebuildDays.isEmpty {
            genManager.start(eventID: event.id, retryDays: work.rebuildDays,
                             appState: appState, regenerateGraphics: true)
        }
    }
}
