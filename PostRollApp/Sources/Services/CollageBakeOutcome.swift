import Foundation

/// What happened when the export tried to bake Dan's collage edits onto the
/// approved base image (#447).
///
/// Why this is not a `URL?`: the bake had four ways to come back nil and the
/// export treated all four as "nothing to do here", falling through to copying
/// the approved preview. For a collage day that preview is Python's raw base
/// PNG, which carries none of the crop offsets or cell edits. So the export
/// finished clean, the folder looked complete, and it held an image Dan had not
/// approved. Every neighbouring degradation on this path is reported (#357,
/// #377); this one landed in neither slot.
enum CollageBakeOutcome: Equatable {

    /// The edits were applied and written here.
    case baked(URL)

    /// There was nothing to bake from: this day has no approved collage, or the
    /// file it names is gone. Deliberately silent here, because the copy step
    /// looks for the same file and reports its absence itself, and two notices
    /// about one missing file is its own defect.
    case nothingToBake

    /// A collage WAS there and Dan's edits could not be put onto it, so the
    /// folder will carry the machine's version and look complete.
    case couldNotApplyEdits(Reason)

    enum Reason: Equatable {
        /// Neither the saved cell layout nor the sidecar matches this day's
        /// current photos, usually because the photo set changed after the
        /// layout was saved. Rendering from it would leave holes.
        case layoutDoesNotMatchThePhotos
        /// The render or the PNG write failed.
        case renderFailed
    }
}

/// The words for a bake that could not be applied.
///
/// Out of the view so a test can pin them: this sentence is the only thing
/// standing between Dan and uploading an image he did not approve, so it has to
/// name the day and say what he is actually getting.
enum CollageBakeNotice {

    static func sentence(_ failures: [(day: String, reason: CollageBakeOutcome.Reason)]) -> String? {
        guard !failures.isEmpty else { return nil }
        let lines = failures.map { "\($0.day): \(describe($0.reason))" }
        let subject = failures.count == 1 ? "day" : "days"
        return "Your collage edits could not be applied to \(failures.count) \(subject), so the "
             + "export carries the version PostRoll generated rather than the one you "
             + "adjusted:\n" + lines.joined(separator: "\n")
    }

    static func describe(_ reason: CollageBakeOutcome.Reason) -> String {
        switch reason {
        case .layoutDoesNotMatchThePhotos:
            return "the saved cell layout does not match this day's photos, so it was not used"
        case .renderFailed:
            return "the collage could not be redrawn"
        }
    }
}
