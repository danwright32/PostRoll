import SwiftUI

/// What a posting layout switch will replace, said in terms of this event
/// (#1007).
///
/// Pure, and here rather than inside the view, for the reason `PostingLayoutCopy`
/// is: the sentence it replaced was a two way ternary inside a view body, which
/// no test could reach, and it was wrong for a year.
enum PostingLayoutSwitch {

    /// The confirmation for switching `event` to `preset`, or nil when there is
    /// nothing to confirm.
    ///
    /// nil rather than an empty string: a dialog that appears with nothing to
    /// say trains Dan to dismiss the one that matters, and a switch that
    /// rebuilds nothing takes nothing away.
    ///
    /// Derived from the days that would actually rebuild and from whether their
    /// captions carry edits, never asserted. A warning shown identically on
    /// every switch carries no information (L180).
    static func confirmation(switchingTo preset: PostingPreset,
                             in event: Event,
                             defaults: UserDefaults) -> String? {
        let days = preset.affectedDays(in: event)
        guard !days.isEmpty else { return nil }

        let all = SentenceList.of(days.map(\.displayName))

        // `wasEdited`, never a raw `caption != generatedCaption`.
        // `generatedCaption` is empty until `stampOriginals` runs, so the raw
        // comparison reads every unstamped day as edited and warns Dan about
        // work he never did. A warning that cries wolf stops being read (L36).
        let edited = days.filter { event.weekResult?[$0]?.wasEdited == true }

        guard !edited.isEmpty else {
            return "This rebuilds the captions and images for \(all)."
        }
        let editedList = SentenceList.of(edited.map(\.displayName))
        return "This rebuilds the captions and images for \(all). "
             + "Your edits to \(editedList) will be replaced."
    }
}

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
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small).tint(PaintedSurfaces.iconAccent)
                    Text("Rebuilding this event, so the layout cannot change yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
            } else {
                Text(PostingLayoutCopy.thisEvent(effectivePreset))
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
                PostingLayoutSwitch.confirmation(switchingTo: $0, in: live, defaults: defaults)
            } ?? "")
        }
    }

    /// Confirm only when there is something to lose. A switch on an event with
    /// no photos rebuilds nothing, so it applies straight away rather than
    /// asking a question with no consequence behind it.
    private func request(_ newValue: PostingPreset) {
        let ev = live
        guard newValue != ev.effectivePostingPreset(in: defaults) else { return }
        if PostingLayoutSwitch.confirmation(switchingTo: newValue, in: ev, defaults: defaults) == nil {
            apply(newValue)
        } else {
            pending = newValue
        }
    }

    /// Set this event's override and rebuild the days it governs.
    ///
    /// Still the whole affected set, which is more than a switch needs to
    /// touch. Narrowing that to the days whose post actually changes is #1010,
    /// which lands the decision separately; this change is about WHERE the
    /// control is, and deliberately does not alter what a switch does.
    private func apply(_ newValue: PostingPreset) {
        var ev = live
        guard newValue != ev.effectivePostingPreset(in: defaults) else { return }
        ev.postingPresetOverride = newValue

        let affected = newValue.affectedDays(in: ev).map(\.rawValue)
        for day in affected { ev.previewMediaPaths.removeValue(forKey: day) }
        appState.updateEvent(ev)

        if !affected.isEmpty {
            genManager.start(eventID: event.id, retryDays: Set(affected), appState: appState,
                             regenerateGraphics: true)
        }
    }
}
