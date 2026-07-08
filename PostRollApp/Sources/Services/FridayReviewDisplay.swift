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
}
