import Foundation

/// Which photograph each alt text describes, for the days generated before
/// anything recorded it (#1035).
///
/// #1008 added `alt_text_photo_paths` so an alt text carries the photo it is
/// about, and `DayCaption.altText(for:at:)` resolves by path when the anchors
/// are there. Every event saved before that has none and falls back to matching
/// by POSITION, which is the exact fragility #1008 removed: reordering a day's
/// photos, or deleting one from the middle, silently moves every alt text onto
/// a different photograph.
///
/// Alt text is what a screen reader user gets instead of the photograph, and a
/// mismatched one reads as plausible because alt text from one shoot resembles
/// its neighbours. So a wrong anchor is worse than none.
///
/// This recovers what can be recovered and leaves the rest alone. A day whose
/// photographs have already moved cannot be recovered at all: the positions are
/// no longer the ones the alt texts were written against, and stamping anchors
/// from them would write a guess down as a fact (L192).
enum AltTextAnchors {

    /// The anchors for one day, or nil when position can no longer be trusted.
    ///
    /// Only when the counts still agree. One alt text per photograph is what
    /// the generator wrote, so a day that still has as many photographs as
    /// descriptions is a day nothing has been removed from or added to, and
    /// position is exactly what it was.
    ///
    /// A REEL day is refused whatever the counts say: its single alt text
    /// describes the whole video rather than one frame, so anchoring it to a
    /// photograph would be a fact nobody stated (#1069).
    static func recoverable(day: DayName, photos: [URL],
                            altTexts: [String]) -> [String]? {
        guard !day.isReelDay,
              !altTexts.isEmpty,
              photos.count == altTexts.count
        else { return nil }
        return photos.map(\.path)
    }

    /// Stamp every day that can be, across every event.
    ///
    /// Run where the stored events are read, because that is the one moment
    /// every event passes through and the population this exists for is
    /// entirely historical: anything generated from now on arrives with its
    /// anchors already on it.
    ///
    /// A day that already has anchors is left exactly as it is. This is a
    /// backfill, not a re-derivation, and re-deriving would overwrite the
    /// anchors Python wrote with ones inferred from wherever the photos sit
    /// now.
    static func backfill(_ events: [Event]) -> [Event] {
        events.map { event in
            guard var week = event.weekResult else { return event }
            var changed = false
            for day in DayName.allCases {
                guard var caption = week[day],
                      caption.altTextPhotoPaths.isEmpty,
                      let photos = event.days[day.rawValue]?.photoPaths,
                      let anchors = recoverable(day: day, photos: photos,
                                                altTexts: caption.altTexts)
                else { continue }
                caption.altTextPhotoPaths = anchors
                week[day] = caption
                changed = true
            }
            guard changed else { return event }
            var stamped = event
            stamped.weekResult = week
            return stamped
        }
    }
}
