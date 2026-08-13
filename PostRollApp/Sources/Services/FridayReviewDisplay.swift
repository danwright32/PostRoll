import Foundation

/// Pure decision for whether Friday's review card shows the dual-slot
/// reel+story layout (#135) vs today's story-only fallback, extracted from
/// CaptionSection so it's unit-testable without SwiftUI/AppKit.
enum FridayReviewDisplay {
    /// Both a real plan AND an on-disk reel file are required. A stale
    /// plan whose rendered file was since deleted or was never rendered
    /// (previewMediaPaths cleared, ArchiveCleanup reclaim, etc.) must fall
    /// back to the story-only card, not show a broken video player.
    static func showsDualSlot(
        fridayClipPlan: FridayClipPlan?,
        reelPath: String?,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard let plan = fridayClipPlan, !plan.selections.isEmpty else { return false }
        guard let reelPath, fileExists(reelPath) else { return false }
        return true
    }

    /// generate_media.py signals "< 3 usable clips" with a distinguishable
    /// insufficient_clips: prefix, deliberately, so this check is an
    /// intentional wire contract rather than string-matching a message
    /// meant for humans.
    static func isInsufficientClipsError(_ message: String) -> Bool {
        message.hasPrefix("insufficient_clips:")
    }

    /// What the review card says about the crops in the cut, or nil when there
    /// is nothing to say (#489).
    ///
    /// `crop_confidence` was decoded, persisted into events.json and documented
    /// as the gate's final decision, and then read by nothing: a stored field
    /// with a writer and no reader looks alive to any is-this-used check, so
    /// the thing it was added for silently never happened (L46).
    ///
    /// What it actually means is worth showing. `apply_selection` sets a clip
    /// to "low" and centres it whenever the crop it was given could not be
    /// trusted for that shot, so a low count is the number of clips Dan is
    /// seeing uncropped rather than framed the way the selection asked for.
    static func cropNote(_ plan: FridayClipPlan?) -> String? {
        guard let plan, !plan.selections.isEmpty else { return nil }
        let uncropped = plan.selections.filter { $0.cropConfidence != "high" }.count
        guard uncropped > 0 else { return nil }
        let subject = uncropped == 1 ? "clip is" : "clips are"
        return "\(uncropped) of \(plan.selections.count) \(subject) shown uncropped: "
             + "the framing suggested for \(uncropped == 1 ? "it" : "them") was not "
             + "confident enough to use."
    }
}
