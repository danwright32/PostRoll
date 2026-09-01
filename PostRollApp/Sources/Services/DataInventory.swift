import Foundation

/// What is actually inside the data folder, for the doc somebody reads while
/// they are losing data (#495).
///
/// Derived from `AppPaths.Layout` rather than typed out beside it, because the
/// hand-kept version had drifted in both directions at once: it promised an
/// `output/` folder nothing has ever created, and it left out three real items,
/// one of which (`brand-voice.md`) holds notes Dan wrote. A wrong inventory is
/// worst in exactly the situation this doc exists for (L32, L41).
///
/// Two entries do not come from `Layout` because Python owns them, not the app.
/// They are declared here and pinned from the Python side by
/// `tests/test_backup_doc_inventory.py`, so neither language can rename its own
/// folder and leave the doc describing the other one.
enum DataInventory {

    struct Item: Equatable {
        /// Exactly as it appears in Finder. A trailing slash marks a folder.
        let name: String
        let holds: String
        let replaceable: String
    }

    /// Names the app itself writes, from the one place that defines them.
    private static let layout = AppPaths.Layout(root: URL(fileURLWithPath: "/"))

    private static func folder(_ url: URL) -> String { url.lastPathComponent + "/" }

    static let items: [Item] = [
        Item(name: layout.eventsFile.lastPathComponent,
             holds: "Every event, caption, blog post, OCR result, tag and crop edit",
             replaceable: "No. This is the important one."),
        Item(name: layout.eventsFile.lastPathComponent + ".<date>.bak",
             holds: "Recent verified-good copies of the above",
             replaceable: "Copies"),
        Item(name: layout.analyticsFile.lastPathComponent,
             holds: "Imported Instagram history and reports",
             replaceable: "Only by re-exporting from Meta"),
        Item(name: layout.analyticsFile.lastPathComponent + ".<date>.bak",
             holds: "Recent verified-good copies of the above",
             replaceable: "Copies"),
        Item(name: layout.accountsFile.lastPathComponent,
             holds: "Follower and engagement numbers you typed in by hand",
             replaceable: "No, only by looking them up again"),
        Item(name: layout.brandVoiceFile.lastPathComponent,
             holds: "Your brand voice notes, including everything the app has learned",
             replaceable: "No, unless you still have the copy in the project folder"),
        Item(name: folder(layout.photosDir),
             holds: "Every photo you imported",
             replaceable: "No, unless you still have the originals"),
        Item(name: folder(layout.clipsDir),
             holds: "Every video clip you imported",
             replaceable: "No, unless you still have the originals"),
        Item(name: folder(layout.programsDir),
             holds: "Program scans and the searchable program PDFs",
             replaceable: "No. The sites they came from block re-download."),
        Item(name: folder(layout.audioDir),
             holds: "Music you picked for a reel",
             replaceable: "Yes, re-downloadable"),
        Item(name: audioCacheDirName + "/",
             holds: "Downloaded music the app keeps so it does not fetch a track twice",
             replaceable: "Yes, re-downloaded on demand"),
        Item(name: folder(layout.previewDir),
             holds: "Generated collages, reels and story graphics",
             replaceable: "Yes, regenerated on demand"),
        Item(name: folder(layout.progressDir),
             holds: "Which step a running generation is on",
             replaceable: "Yes, scratch files"),
        Item(name: folder(layout.logsDir),
             holds: "Diagnostic logs",
             replaceable: "Yes"),
        Item(name: repairLogFileName,
             holds: "What the app changed in each blog post: the alt text "
                  + "before and after every silent repair",
             replaceable: "No. Repairs are silent, so this is the only record "
                        + "that a rewrite happened at all"),
        Item(name: usageLogFileName,
             holds: "What each paid AI call cost, for the spend figures in the app",
             replaceable: "No, but it is a record rather than something the app needs"),
    ]


    /// Written by Python (`postroll/audio.py`), under the same data root.
    static let audioCacheDirName = "audio_cache"

    /// Written by Python (`postroll/ai/usage_log.py`), under the same data root.
    static let usageLogFileName = "usage.jsonl"

    /// Written by the Python side, so this can only declare the name; the
    /// Python guard pins it to what that code actually computes.
    static let repairLogFileName = "blog-repairs.jsonl"

    /// The inventory as the Markdown table rows the doc carries, so the doc can
    /// be checked against this rather than read and believed.
    static var markdownRows: [String] {
        items.map { "| `\($0.name)` | \($0.holds) | \($0.replaceable) |" }
    }
}
