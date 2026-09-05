import Foundation

/// What a day's alt text is supposed to describe (#1069).
///
/// The review screen showed alt text as a sentence beside the caption with
/// nothing saying what that sentence covers. On a reel day it describes a video
/// built from every photograph of the event, often fifty to two hundred of
/// them. On a carousel day there is one per photo. On a single feed photo it is
/// that photo. All three looked identical on screen.
///
/// Alt text is the one part of a post nobody can verify by looking at the post,
/// so the review screen is the only place the error can be caught, and #1067
/// shipped for months partly because a single photo description sitting beside
/// a Thursday card reads as perfectly fine.
enum AltTextScope {

    /// The line under the ALT TEXTS heading, or nil when the day has none.
    ///
    /// `photos` is what the DAY holds, not what the caption was written from.
    /// A reel's alt text is written from a sample of the photographs while the
    /// reel is built from all of them, and naming the sample here would tell
    /// the reviewer to check the description against the wrong set: worse than
    /// saying nothing, because it reads as a fact.
    static func line(day: DayName, isCarousel: Bool,
                     photos: Int, altTexts: Int,
                     anchored: Bool = true) -> String? {
        guard altTexts > 0 else { return nil }
        if day.isReelDay {
            // Said as a fault rather than as a description, because a reel
            // takes ONE description of the whole thing and more than one is the
            // model having written one per photograph, which is #1067's defect
            // exactly. The screen has to disagree with itself out loud rather
            // than print a sentence the list beneath it contradicts (L11).
            if altTexts > 1 {
                return "A reel takes one description of the whole video, and "
                     + "this has \(altTexts). The extra ones describe single "
                     + "moments nobody will see on their own."
            }
            return "Describes the whole reel, built from "
                 + "\(photos) \(photos == 1 ? "photograph" : "photographs")."
        }
        if isCarousel {
            // An unanchored day is one #1035 could not recover: its photographs
            // had already moved when the anchors were stamped, so which
            // description belongs to which photograph is genuinely unknown and
            // the position they are listed in is a guess. Said out loud rather
            // than presented as an order, because a mismatched alt text reads
            // as plausible: it is alt text from the same shoot.
            let unknown = anchored ? "" : " The order is unverified: these were "
                                        + "written before the app recorded which "
                                        + "photo each one describes, and this "
                                        + "day's photos have changed since."
            return "One per photo, in the order they appear in the carousel"
                 + countNote(photos: photos, altTexts: altTexts) + unknown
        }
        return "Describes the one photograph in this post"
             + countNote(photos: photos, altTexts: altTexts)
    }

    /// Says so when the count does not match the photographs, and nothing when
    /// it does. A number repeated on every ordinary post is noise, and the one
    /// case worth interrupting for is the mismatch (L36).
    private static func countNote(photos: Int, altTexts: Int) -> String {
        guard photos > 0, photos != altTexts else { return "." }
        return ", and there are \(altTexts) for \(photos) "
             + "\(photos == 1 ? "photograph" : "photographs")."
    }
}

extension DayName {
    /// Whether this day's post is a reel rather than a photo or a carousel.
    ///
    /// Tuesday and Thursday, which is where a description of a single moment
    /// reads as reasonable and is wrong.
    var isReelDay: Bool { self == .tuesday || self == .thursday }
}
