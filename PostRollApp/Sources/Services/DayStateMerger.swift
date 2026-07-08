import Foundation

/// Merges CaptionReviewView's local per-day edit state (crop offsets,
/// collage cell overrides, clip overrides) into an Event's days, in place.
///
/// Pulled out as a pure, View-independent function. save() and
/// finalizeAdvance() used to each carry an independent copy of this exact
/// loop; now they share one implementation instead of drifting out of sync.
/// That duplication is what caused a silent edit-loss bug: the Advance-to-
/// Export route calls finalizeAdvance() but not save(), so a field wired
/// into only one copy silently never reached ev.days on that path.
enum DayStateMerger {
    static func mergeLocalStateIntoDays(
        _ ev: inout Event,
        collageCropOffsets: [String: [String: CropOffset]],
        reelCropOffsets: [String: [String: CropOffset]],
        collageCellOverrides: [String: [CollageCell]],
        fridayClipOverride: [String: [ReelClipOverride]]
    ) {
        for (dayKey, offsets) in collageCropOffsets {
            if var pd = ev.days[dayKey] {
                pd.collageCropOffsets = offsets
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, offsets) in reelCropOffsets {
            if var pd = ev.days[dayKey] {
                pd.reelCropOffsets = offsets
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, cells) in collageCellOverrides {
            if var pd = ev.days[dayKey] {
                pd.collageCellOverride = cells
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, overrides) in fridayClipOverride {
            if var pd = ev.days[dayKey] {
                pd.fridayClipOverride = overrides
                ev.days[dayKey] = pd
            }
        }
    }
}
