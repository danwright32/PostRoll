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
                     fileManager: FileManager = .default) -> [StaleDay] {
        var found: [StaleDay] = []
        for eventDir in directories(in: previewRoot, fileManager: fileManager) {
            for dayDir in directories(in: eventDir, fileManager: fileManager) {
                let stale = DesignStamp.staleTemplates(in: dayDir)
                guard !stale.isEmpty else { continue }
                found.append(StaleDay(eventSlug: eventDir.lastPathComponent,
                                      dayFolder: dayDir,
                                      dayLabel: dayLabel(from: dayDir.lastPathComponent),
                                      templates: stale))
            }
        }
        return found
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
