import Foundation

/// When the programme review screen must take up what was stored underneath it
/// (#518).
///
/// The review screen loads its working copy of the OCR result once, at init,
/// and is keyed on the event id, so it does not reload when that event's stored
/// result changes. Every edit flows the other way: the draft is persisted to the
/// event as it is typed.
///
/// That held for as long as nothing else wrote the result while the screen was
/// open. The targeted rescan is the first thing that does. Without this rule a
/// successful rescan saved the newly read pages, the screen went on showing the
/// older draft so the rescan looked like it had done nothing, and the next
/// keystroke persisted that stale draft back over the merge, discarding the
/// pages just read and paid for.
///
/// A correct save that still shows the old value reads as a failed save, and
/// here it did not merely read as one, it became one (L14, L17).
enum OCRDraftRefresh {

    /// Whether the on screen draft should be replaced by what is stored.
    ///
    /// Never while a run is in flight: the stored result is mid-write and the
    /// screen would adopt a half-finished state.
    ///
    /// Never when the two already agree, which is the ordinary case on every
    /// keystroke, because the draft is persisted as it is typed. Adopting then
    /// would be a pointless write, and writing on every change is how two
    /// values that update each other start looping.
    ///
    /// Never from an absent stored result, which would blank the screen.
    static func shouldAdopt(stored: OCRResult?, draft: OCRResult,
                            isRunning: Bool) -> Bool {
        guard !isRunning, let stored else { return false }
        return stored != draft
    }
}
