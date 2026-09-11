import Foundation

/// Whether exporting would quietly change a reel Dan has already approved
/// (#1407).
///
/// A Thursday carrying any hand adjusted framing is sent to Python on every
/// export rather than copied from the approved preview, so its crops bake in.
/// When that day has no stored `reelSeed`, the render mints one (#1403) and
/// arranges the photographs differently from the video that was reviewed and
/// posted. Nothing said so, and the only signal was the finished video looking
/// wrong afterwards.
///
/// This cannot be repaired by backfilling: those arrangements came from entropy
/// that was never written down, so they are not reproducible. The remedy is to
/// ask before the render, not to explain after it.
///
/// The question belongs here rather than in the export screen, because three
/// buttons in `ExportView` reach `ExportManager.start` and the fourth one
/// somebody adds would miss a check written beside the other three (the same
/// reason `ExportReadiness` lives where it does).
enum ReelRelayoutNotice {

    /// The reel asset, under the key the preview run writes and every reader
    /// already uses.
    private static let reelKey = "reel"

    /// What Dan is being asked, when he is being asked anything.
    struct Question: Equatable {
        let day: DayName

        /// Whether the approved video can actually be kept.
        ///
        /// NOT the same as the reel file existing. Keeping it means taking the
        /// copy path, and `PreviewMergePolicy.copyPreviewAssetsIfComplete`
        /// refuses unless EVERY preview file for the day is on disk, then falls
        /// through to a re-render. An offer to keep the video made without
        /// checking that would do the precise opposite of what it says, which
        /// is the defect this notice exists to prevent (L111).
        let canKeepApproved: Bool

        /// What the export screen says, in terms of what happens to the reel
        /// rather than what the program does to produce it (L604).
        var message: String {
            let lead = "\(day.displayName)'s reel was put together before PostRoll started "
                     + "remembering how a reel is arranged, so exporting lays the photos "
                     + "out differently from the video you approved."
            return canKeepApproved
                ? lead + " You can keep the video you have instead."
                : lead + " The video you have cannot be kept: the files it was exported "
                       + "with are no longer all there, so this day has to be made again."
        }
    }

    /// The question this event owes, or nil when exporting changes nothing.
    ///
    /// Nil in three distinct situations that all mean "say nothing": the layout
    /// was recorded, so the render reproduces it; there is no rendered reel, so
    /// nothing has been approved; or the day has no photographs and renders no
    /// reel at all. Each is tested separately, because a stored path reads as
    /// presence until it is stat'd.
    ///
    /// The file manager is injectable so tests run against a temporary tree
    /// rather than whatever happens to be in the real preview folder.
    static func question(for event: Event,
                         fileManager fm: FileManager = .default) -> Question? {
        let day = DayName.thursday
        guard let pd = event.days[day.rawValue],
              !pd.photoPaths.isEmpty,
              pd.reelSeed == nil
        else { return nil }

        let assets = event.previewMediaPaths[day.rawValue] ?? [:]
        guard let reel = assets[reelKey], fm.fileExists(atPath: reel) else { return nil }

        return Question(day: day,
                        canKeepApproved: assets.values.allSatisfy {
                            fm.fileExists(atPath: $0)
                        })
    }
}
