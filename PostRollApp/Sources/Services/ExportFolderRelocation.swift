import Foundation

/// Saying where a finished export went (#1110).
///
/// Dan files every finished export into one of his own Finder buckets, so the
/// path the export run recorded stops being true almost immediately: measured
/// against the live store on 2026-09-02, 0 of the 9 recorded export folders
/// were still at their recorded path. `ExportFolderStatus.lostTrack` says so
/// plainly rather than claiming the export was lost; this is the way out of
/// that state, and the reason the message can name a step that actually
/// changes it (L111).
enum ExportFolderRelocation {

    /// The live event with `folder` recorded as where its export went, or nil
    /// when nothing should be written.
    ///
    /// Takes the whole array rather than one event for the same reason
    /// `EventStageTransition.applying` does: the live record is looked up here,
    /// so a caller cannot hand in its stale copy by accident.
    ///
    /// Refuses rather than recording a path that is already wrong. Replacing
    /// one record the app cannot find with another it cannot find reads as a
    /// repair on the screen while leaving exactly the state it was meant to
    /// clear (L5), and every later read would report the same thing.
    static func applying(_ folder: URL,
                         toEventWithID id: Event.ID,
                         in events: [Event]) -> Event? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        guard var live = events.first(where: { $0.id == id }) else { return nil }
        live.exportPath = folder
        return live
    }
}
