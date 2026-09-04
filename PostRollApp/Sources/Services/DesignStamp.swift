import Foundation

/// Which design rendered a day's cached assets (#286).
///
/// #160 gave the collage a version, carried in the layout sidecar that already
/// sat beside its PNG, so a collage from before the gallery redesign is badged
/// on the review screen instead of quietly rendering the old look forever. The
/// reels and the stills have no sidecar and got no stamp, so a cached Thursday
/// scroll reel, Tuesday reel, before/after or story from before that same
/// redesign kept rendering the old design with nothing saying so. The reels are
/// the worst case: re-rendering one is expensive enough that nobody does it
/// speculatively, so a stale one survives longest.
///
/// The record is one file per day folder rather than one per asset, because
/// "is this day's output current" is then one read instead of one per file, and
/// regenerating a day rebuilds all of it at once anyway.
///
/// `postroll/media/design_stamp.py` is the writing half.
/// `tests/test_media_design_version.py` is the contract both satisfy.
enum DesignStamp {

    /// The record's name inside a day folder.
    static let stampName = "design.json"

    // MARK: - Reading

    /// The template versions recorded for a day, or [:] if there is no record.
    ///
    /// Never throws. Every day folder rendered before this existed has no
    /// stamp, and that is a fact about the day rather than an error. A version
    /// that is not an integer is dropped rather than believed, because a value
    /// that cannot be compared would otherwise land on the fresh side of every
    /// comparison it touches (L50).
    static func read(in dayDir: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: dayDir.appendingPathComponent(stampName)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let templates = doc["templates"] as? [String: Any]
        else { return [:] }
        // Per entry rather than all-or-nothing, because Python's reader drops
        // per entry and two readers of one file that disagree about a bad value
        // is the whole class of defect this pairing exists to avoid (L26). A
        // Codable decode into [String: Int] would throw the good entries away
        // alongside the bad one.
        var versions: [String: Int] = [:]
        for (name, value) in templates {
            guard let number = value as? NSNumber,
                  // A JSON true decodes to an NSNumber that answers to intValue,
                  // and 1 is a plausible-looking version.
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  // 1.5 is not a version either. Dropped rather than truncated,
                  // because truncating invents a value nothing wrote.
                  Double(number.intValue) == number.doubleValue
            else { continue }
            versions[name] = number.intValue
        }
        return versions
    }

    /// Which versioned templates actually have an asset sitting in this folder.
    ///
    /// Read off the disk, not off the stamp. The question is whether the cached
    /// assets are old, so the assets are what has to be enumerated: a stamp is a
    /// claim about them, and a folder full of assets with no stamp at all is
    /// precisely the case this was written for.
    static func cachedTemplates(in dayDir: URL) -> [String] {
        cachedAssets(in: dayDir).keys.sorted()
    }

    /// The same assets, with the file each one was found at (#804).
    ///
    /// The file is what carries the modification date the unstamped rule reads.
    /// `cachedTemplates` is derived from this rather than scanning separately,
    /// so the two cannot disagree about what a day folder holds (L41).
    ///
    /// One entry per template: a folder holding two files with the same stem
    /// keeps whichever the scan reached last, which is the only arrangement a
    /// render never produces.
    static func cachedAssets(in dayDir: URL) -> [String: URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stem = entry.deletingPathExtension().lastPathComponent
            guard MediaDesign.version(of: stem) != nil else { continue }
            found[stem] = entry
        }
        return found
    }

    /// Which cached assets in a day folder predate the design this build renders.
    ///
    /// Sorted, because the badge names them and a set's order would reword the
    /// message on every read.
    ///
    /// Reported on EVIDENCE only, and since #804 there are two kinds of it: a
    /// version was recorded and is behind, or no version was recorded and the
    /// file's own date puts it before the day that template's design changed.
    /// An asset with neither is still not reported.
    ///
    /// That was measured rather than assumed (2026-08-10). Treating "no record"
    /// as stale badged all 66 day folders on Dan's machine at once, because none
    /// carried a stamp yet, and a badge on every day is one nobody reads (L36).
    ///
    /// The second half of that reasoning was wrong, and re-measuring it is what
    /// closed #311 (2026-08-11). It said those assets were not old either,
    /// because the gallery redesign landed 2026-07-14 and the newest previews
    /// were rendered 2026-08-07. That compared the redesign against the NEWEST
    /// preview only. Read across the whole library instead: 38 of the 66 day
    /// folders hold nothing rendered since 2026-07-14 at all, and two later
    /// changes (the bottom-only crop on 2026-08-07 22:07, the shared org and
    /// venue detail lines on 2026-08-10) both postdate the newest asset on disk.
    /// So every cached asset predates the design this build renders, and the
    /// silent case is currently hiding the entire library rather than costing
    /// nothing.
    ///
    /// That cost is accepted deliberately, not overlooked. The alternative was
    /// to write a version onto those folders, and a stamp is a RECORD:
    /// asserting they were made by the current design would be a claim the file
    /// dates contradict, and it would permanently destroy the ability to tell a
    /// measured stamp from a guessed one. Saying nothing is the honest state
    /// until a day is rendered again, and every render from here leaves a
    /// stamp, so a future design change is caught by evidence rather than by
    /// absence.
    ///
    /// An asset stamped NEWER than this build is not stale either: regenerating
    /// it here would replace a better asset with an older design.
    /// Every design version recorded for a day, from both places one can live.
    ///
    /// The day's own stamp plus the collage's layout sidecar, which is a record
    /// too. Empty means nothing about this day could be compared against
    /// anything, which is a different answer from "compared and current" and is
    /// the state every day folder on Dan's Mac is in (#311).
    static func recorded(in dayDir: URL) -> [String: Int] {
        withCollageFromItsSidecar(in: dayDir, read(in: dayDir))
    }

    /// `changedDays` is injectable so a rule can be driven against a table that
    /// actually contains its case (#921).
    ///
    /// Both rules about a template with NO recorded change used to be tested by
    /// reading the shipping table and taking whatever had none. That worked
    /// until the collage got one and the set went empty, at which point the
    /// tests correctly refused to pass over nothing. A rule is tested by
    /// feeding it the case, not by hoping the shipping data still holds one
    /// (L1). Defaulted, so every caller in the app is unchanged.
    static func staleTemplates(
        in dayDir: URL,
        changedDays: [String: String] = MediaDesign.mediaDesignChanged
    ) -> [String] {
        let recorded = recorded(in: dayDir)
        // Scanned once. Asking inside the filter would re-read the folder for
        // every template it holds.
        let assets = cachedAssets(in: dayDir)
        return assets.keys.sorted().filter { name in
            guard let current = MediaDesign.version(of: name),
                  let path = assets[name] else { return false }
            // A record beats an inference, in both directions: an asset stamped
            // current is not badged for being old, and one stamped behind is
            // badged however new the file is.
            if let stamped = recorded[name] { return stamped < current }
            return predatesItsDesignChange(name, at: path, changedDays: changedDays)
        }
    }

    /// Whether an asset was written before the day its template's design
    /// changed (#804).
    ///
    /// The half of the badge that needs no stamp. It answers false wherever
    /// there is no evidence, and those are different situations that must not
    /// be read as each other: a template with no recorded design CHANGE has
    /// nothing to be older than, and a file whose date cannot be read says
    /// nothing about when it was made.
    ///
    /// Compared as calendar days, matching the Python half. An asset written ON
    /// the day of the change, before the change itself, reads as current, which
    /// under-reports by less than a day. That is the safe direction for a badge
    /// that sends somebody to re-render, and a copied or synced file carries a
    /// date at or after its real render rather than before it, so the same
    /// direction holds for a library that has been moved.
    static func predatesItsDesignChange(
        _ template: String,
        at path: URL,
        changedDays: [String: String] = MediaDesign.mediaDesignChanged
    ) -> Bool {
        guard let changed = MediaDesign.changedDay(changedDays[template]) else { return false }
        guard let written = try? path.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return false }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.startOfDay(for: written) < calendar.startOfDay(for: changed)
    }

    /// Fill in the collage's version from the sidecar #160 already writes.
    ///
    /// Every day folder on disk the day this ships is in exactly one state: no
    /// day stamp, and a collage whose layout sidecar already records the design
    /// that made it. Ignoring that would badge collages the app has always read
    /// as current, and send Dan to rebuild something that is not out of date.
    ///
    /// The day stamp wins where it has an entry: it is the record for the day,
    /// and a sidecar left by a partial write must not override what the day says
    /// about itself. A sidecar with no version (the bare-array shape written
    /// before #160) fills in nothing, so "no version recorded" cannot become a
    /// clean bill of health.
    private static func withCollageFromItsSidecar(
        in dayDir: URL, _ recorded: [String: Int]
    ) -> [String: Int] {
        guard recorded["collage"] == nil else { return recorded }
        let sidecar = LayoutSidecar.url(for: dayDir.appendingPathComponent("collage.png"))
        guard let version = LayoutSidecar.read(at: sidecar).version else { return recorded }
        var filled = recorded
        filled["collage"] = version
        return filled
    }

    // MARK: - What the badge says

    /// What to call a template in a sentence.
    ///
    /// A badge naming a raw filename stem ("reel_morph is out of date") reads as
    /// a bug report rather than as something to act on. Falls back to the stem
    /// with its underscores opened up, so a template added without a label here
    /// still produces a sentence rather than a crash, and the test that every
    /// known template has a readable label catches the omission.
    static func label(for template: String) -> String {
        switch template {
        case "collage":      return "collage"
        case "story":        return "story graphic"
        case "cover":        return "cover image"
        case "before_after": return "before and after graphic"
        case "reel_screen":  return "speed edit reel"
        case "reel_morph":   return "before and after reel"
        case "reel_slider":  return "three photo reveal reel"
        case "reel_scroll":  return "scroll reel"
        case "reel_preview": return "scroll reel preview"
        case "reel_clip":    return "clip reel"
        default:             return template.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The banner sentence for a day whose assets predate the current design,
    /// or nil when there is nothing to say.
    ///
    /// Names what is affected rather than saying "something here is old",
    /// because a message that leaves the person to go and find its target is
    /// half a message (L80).
    ///
    /// One message for what is now two causes (#804), because both establish
    /// the same fact and carry the same remedy: a stamp behind the current
    /// version, and a file written before the day the design changed, each mean
    /// this asset was made by an older design and regenerating the day rebuilds
    /// it. A day with neither still says nothing at all.
    static func staleMessage(for stale: [String]) -> String? {
        guard !stale.isEmpty else { return nil }
        let names = stale.map(label(for:))
        let one = names.count == 1
        let listed = SentenceList.of(names)
        return "The \(listed) here \(one ? "was" : "were") made with an older "
             + "version of the design, so \(one ? "it does" : "they do") not match "
             + "the current one. Regenerate the day to rebuild \(one ? "it" : "them")."
    }
}
