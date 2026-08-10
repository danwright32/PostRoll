import Foundation

/// What a day IS, for both of the manifests that cross to Python (#138).
///
/// `PythonBridge.buildMediaManifest` feeds generate_media (images and reels)
/// and `PythonBridge.buildManifest` feeds generate_week (captions and blog).
/// Each used to carry its own near-identical copy of the inclusion guard and of
/// the fields both pipelines need, kept in step by hand.
///
/// That duplication caused a real gap in the Friday clip reel plan: the draft
/// updated only the media builder, so the caption pipeline would never have
/// learned clips existed no matter how well the rest of the feature worked. It
/// was caught by a code-level fact-check before any code was written, which is
/// not a process the next feature is guaranteed.
///
/// Fields that only ONE pipeline needs stay in that pipeline's builder. What
/// belongs here is anything both are supposed to agree about.
enum ManifestDay {

    /// Whether this day has anything worth sending.
    ///
    /// One rule for both manifests, because a day that reaches one pipeline and
    /// not the other is either a caption describing assets nobody made, or
    /// assets no caption mentions. Clips count on their own: Friday's auto-cut
    /// reel needs no stills at all.
    static func isIncluded(_ pd: PostingDay?) -> Bool {
        guard let pd else { return false }
        return !pd.photoPaths.isEmpty
            || pd.rawPhotoPath != nil
            || pd.editedPhotoPath != nil
            || !pd.clipPaths.isEmpty
    }

    /// The fields BOTH manifests carry, so a new one is added once.
    ///
    /// `photos` is deliberately not re-sorted. photoPaths is the source of
    /// truth for reel and collage order: it is sorted once at import and every
    /// user-driven reorder lives there, so sorting here would silently revert a
    /// manual swap on every regeneration.
    static func sharedEntry(_ pd: PostingDay, day: DayName) -> [String: Any] {
        var entry: [String: Any] = ["photos": pd.photoPaths.map { $0.path }]

        // A manual cover override always wins over the AI pick, the same
        // nil-means-AI semantics as collageCellOverride. Captions need it as
        // well as the renderer, so it lives here.
        if let source = pd.coverOverride ?? pd.coverPick?.sourcePath {
            entry["cover_source"] = source
        }

        // Friday's source clips. The pipeline that renders the reel and the one
        // that writes about it both have to know they exist, which is the very
        // field this helper was created over.
        if !pd.clipPaths.isEmpty {
            entry["clips"] = pd.clipPaths.map { $0.path }
        }

        return entry
    }
}
