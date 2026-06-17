import Foundation

/// Reclaims the duplicated user data left behind in the legacy
/// `~/Documents/PostRoll` location after the move to Application Support.
///
/// `DataMigration` copies (never moves) and leaves the originals as a fallback,
/// so post-migration every data folder exists twice. This deletes the legacy
/// copies — but ONLY a strict allowlist of data items, never the folder itself,
/// which also holds the Python checkout (postroll/, venv/, .git, tests/, …).
///
/// Safety rules (see the data-migration safety history):
/// - Only offered once the move is verified complete (marker present AND the app
///   is actively reading Application Support), so the originals are genuine
///   duplicates and not the live data.
/// - Each legacy item is deleted only when its Application Support counterpart
///   exists and is non-empty — proof it was migrated.
/// - Manual only: nothing here runs at launch; the user triggers it.
enum LegacyDataReclaim {

    /// Data items duplicated into Application Support that are safe to remove
    /// from the legacy location. An explicit allowlist — NEVER the whole folder.
    static let dataItems = [
        "photos", "programs", "audio", "preview",
        "events.json", "events.json.bak", "analytics.json",
    ]

    struct Report: Equatable {
        var removed: [String]
        var bytesFreed: Int64
    }

    /// True only when the migration to Application Support is verified complete,
    /// so the legacy originals are duplicates rather than the live data.
    static func canReclaim(
        appSupportRoot: URL = AppPaths.appSupportRoot,
        activeRoot: URL = AppPaths.root,
        fileManager fm: FileManager = .default
    ) -> Bool {
        let marker = appSupportRoot.appendingPathComponent(AppPaths.migrationMarker)
        return fm.fileExists(atPath: marker.path)
            && activeRoot.standardizedFileURL.path == appSupportRoot.standardizedFileURL.path
    }

    /// Total size of the reclaimable legacy duplicates, for the UI to show before
    /// the user confirms. 0 when not reclaimable.
    static func reclaimableBytes(
        legacyRoot: URL = AppPaths.legacyDataRoot,
        appSupportRoot: URL = AppPaths.appSupportRoot,
        activeRoot: URL = AppPaths.root,
        fileManager fm: FileManager = .default
    ) -> Int64 {
        guard canReclaim(appSupportRoot: appSupportRoot, activeRoot: activeRoot, fileManager: fm) else { return 0 }
        var total: Int64 = 0
        for item in dataItems where migratedCounterpartExists(item, appSupportRoot: appSupportRoot, fm: fm) {
            total += size(of: legacyRoot.appendingPathComponent(item), fm: fm)
        }
        return total
    }

    /// Deletes the legacy duplicates item by item, each only when its Application
    /// Support counterpart exists and is non-empty. Returns what was freed.
    @discardableResult
    static func reclaim(
        legacyRoot: URL = AppPaths.legacyDataRoot,
        appSupportRoot: URL = AppPaths.appSupportRoot,
        activeRoot: URL = AppPaths.root,
        fileManager fm: FileManager = .default
    ) throws -> Report {
        guard canReclaim(appSupportRoot: appSupportRoot, activeRoot: activeRoot, fileManager: fm) else {
            return Report(removed: [], bytesFreed: 0)
        }
        var removed: [String] = []
        var freed: Int64 = 0
        for item in dataItems {
            let legacy = legacyRoot.appendingPathComponent(item)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            guard migratedCounterpartExists(item, appSupportRoot: appSupportRoot, fm: fm) else { continue }
            let bytes = size(of: legacy, fm: fm)
            try fm.removeItem(at: legacy)
            removed.append(item)
            freed += bytes
        }
        return Report(removed: removed, bytesFreed: freed)
    }

    /// The Application Support copy of `item` exists and is non-empty — the proof
    /// it was migrated, which gates deletion of the legacy original.
    private static func migratedCounterpartExists(_ item: String, appSupportRoot: URL, fm: FileManager) -> Bool {
        let url = appSupportRoot.appendingPathComponent(item)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return !contents.isEmpty
        }
        let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return bytes > 0
    }

    private static func size(of url: URL, fm: FileManager) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let file as URL in en {
                let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if vals?.isRegularFile == true { total += Int64(vals?.fileSize ?? 0) }
            }
        }
        return total
    }
}
