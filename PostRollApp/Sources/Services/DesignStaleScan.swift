import Foundation

/// One day whose cached assets predate the design this build renders (#293).
struct StaleDay: Identifiable, Hashable {
    /// The preview folder's own name for the event, which is the only thing on
    /// disk tying it back to a record: `dciny_vocal_color_2026-03-30`.
    let eventSlug: String
    let dayFolder: URL
    /// "Thursday", read off the folder name the run itself chose.
    let dayLabel: String
    /// Which of the day's assets are behind, as `DesignStamp` names them.
    let templates: [String]
    /// When this day's assets were last exported, or nil when nothing on disk
    /// says they ever were (#925).
    ///
    /// Nil is "nothing here says so", NOT "this day never went out". Every day
    /// folder rendered before `DayExportRecord` existed carries no record, and
    /// the surface reading this has to keep the two apart (L214).
    var exportedAt: Date? = nil

    var id: String { dayFolder.path }

    /// What the row says: "scroll reel and scroll reel preview".
    var listedTemplates: String {
        let names = templates.map(DesignStamp.label(for:))
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}

/// What one walk of the preview library found (#293, #311).
///
/// Three numbers rather than one list, because an empty list has two very
/// different causes and the surface has to tell them apart. `stale` is what was
/// judged and found behind; `daysWithARecord` is how many days could be judged
/// at all; `daysWithAssets` is how many were there to judge.
///
/// #311 is why this is not just a list. Every day folder on Dan's Mac carries no
/// record, so the list is empty and will stay empty until a day is rendered
/// again. An empty list reported as "everything is current" is a clean bill of
/// health nobody measured, which is precisely L98.
struct DesignScanResult: Equatable {
    /// Days judged against a recorded version and found behind.
    var stale: [StaleDay]
    /// Day folders holding at least one asset that carries a design version.
    var daysWithAssets: Int
    /// Of those, how many record which design made them, so could be compared.
    var daysWithARecord: Int

    /// The stale days worth acting on: nothing on disk records them as having
    /// been exported (#925).
    ///
    /// A split rather than a stored count, so the two halves cannot come to
    /// disagree with the list they are drawn from (L16), and so every stale day
    /// lands in exactly one of them.
    var staleNotExported: [StaleDay] { stale.filter { $0.exportedAt == nil } }

    /// The stale days that have already been exported. Rebuilding one does not
    /// reach the copies already in the export folder, so they are set apart
    /// rather than dropped: a day silently removed would make "nothing stale"
    /// and "nothing stale that has not been exported yet" the same answer
    /// (L98).
    ///
    /// Exported, never posted. PostRoll records that the files were written
    /// into a folder and nothing more, and a day can sit exported and still be
    /// waiting to go out, so a rebuild of one of these WOULD change what people
    /// eventually see once it is exported again (#1111).
    var staleExported: [StaleDay] { stale.filter { $0.exportedAt != nil } }
}

/// Every day, across every event, whose cached assets are behind the current
/// design (#293).
///
/// `DesignStamp.staleTemplates(in:)` answers this for one folder, and the
/// caption review screen badges the day it is showing. That badge is only
/// visible on the day you happen to open, and there are 66 day folders across
/// 12 events on disk, so after a design version is bumped there was no way to
/// find which days it dated short of visiting every day of every event. The
/// mechanism only pays off at the moment a design changes, which is exactly the
/// moment it was least usable.
///
/// Walks the disk, so it belongs off the redraw path: call it when a surface
/// opens or is refreshed by hand, never from `body`.
enum DesignStaleScan {

    /// Every stale day under a preview root, event folder order then day order.
    ///
    /// Never throws. A preview root that cannot be listed yields nothing, which
    /// is the same answer as a machine that has rendered nothing: the caller
    /// distinguishes the two by asking `hasPreviewRoot`, because a scan that
    /// found no folders at all is not the same claim as a clean bill of health
    /// (LESSONS.md L98).
    static func scan(previewRoot: URL,
                     fileManager: FileManager = .default) -> DesignScanResult {
        var found: [StaleDay] = []
        var withAssets = 0
        var withARecord = 0
        for eventDir in directories(in: previewRoot, fileManager: fileManager) {
            for dayDir in directories(in: eventDir, fileManager: fileManager) {
                // A folder with nothing versioned in it is not a day that could
                // be old, so counting it would inflate the number the sentence
                // quotes.
                guard !DesignStamp.cachedTemplates(in: dayDir).isEmpty else { continue }
                withAssets += 1
                if !DesignStamp.recorded(in: dayDir).isEmpty { withARecord += 1 }

                let stale = DesignStamp.staleTemplates(in: dayDir)
                guard !stale.isEmpty else { continue }
                // Read only for a day already found stale, which is the only
                // day the answer changes anything about. A day that is current
                // is not listed whether it went out or not.
                found.append(StaleDay(eventSlug: eventDir.lastPathComponent,
                                      dayFolder: dayDir,
                                      dayLabel: dayLabel(from: dayDir.lastPathComponent),
                                      templates: stale,
                                      exportedAt: DayExportRecord.read(in: dayDir)))
            }
        }
        return DesignScanResult(stale: found,
                                daysWithAssets: withAssets,
                                daysWithARecord: withARecord)
    }

    /// Whether there is a preview root to scan at all.
    ///
    /// Kept separate from the result so "nothing has ever been rendered" cannot
    /// be reported as "everything is current".
    static func hasPreviewRoot(_ previewRoot: URL,
                               fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: previewRoot.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Sub-directories, in name order, so the list reads the same on every scan.
    private static func directories(in url: URL,
                                    fileManager: FileManager) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// "5. Thursday" reads as "Thursday".
    ///
    /// The number orders the folders on disk and says nothing to a person. A
    /// name that does not carry one is left exactly as it is rather than being
    /// trimmed to something else.
    static func dayLabel(from folderName: String) -> String {
        guard let dot = folderName.firstIndex(of: "."),
              !folderName[folderName.startIndex..<dot].isEmpty,
              folderName[folderName.startIndex..<dot].allSatisfy(\.isNumber)
        else { return folderName }
        return String(folderName[folderName.index(after: dot)...])
            .trimmingCharacters(in: .whitespaces)
    }
}
