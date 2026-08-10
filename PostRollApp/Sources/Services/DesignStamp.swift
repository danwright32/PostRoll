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
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil)) ?? []
        return Set(entries.map { $0.deletingPathExtension().lastPathComponent })
            .filter { MediaDesign.version(of: $0) != nil }
            .sorted()
    }

    /// Which cached assets in a day folder predate the design this build renders.
    ///
    /// Sorted, because the badge names them and a set's order would reword the
    /// message on every read.
    ///
    /// Reported on EVIDENCE only: a version was recorded, and it is behind. An
    /// asset with no record is not reported, even though that means an asset
    /// older than the stamp itself goes unmentioned.
    ///
    /// That was measured rather than assumed (2026-08-10). Treating "no record"
    /// as stale badged all 66 day folders on Dan's machine at once, because none
    /// carried a stamp yet, and a badge on every day is one nobody reads (L36).
    /// Those assets were not old either: the gallery redesign landed 2026-07-14
    /// and the newest previews were rendered 2026-08-07, three weeks after. So
    /// the silent case costs nothing on the real data and the loud one cost the
    /// whole signal. Every render from here leaves a stamp, so a future design
    /// change is caught by evidence rather than by absence.
    ///
    /// An asset stamped NEWER than this build is not stale either: regenerating
    /// it here would replace a better asset with an older design.
    static func staleTemplates(in dayDir: URL) -> [String] {
        let recorded = withCollageFromItsSidecar(in: dayDir, read(in: dayDir))
        return cachedTemplates(in: dayDir).filter { name in
            guard let current = MediaDesign.version(of: name),
                  let stamped = recorded[name] else { return false }
            return stamped < current
        }
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
    /// There is only one message because there is only one cause: this is
    /// reached only when a version was recorded and is behind. A day with no
    /// record says nothing at all, so there is no second sentence to write.
    static func staleMessage(for stale: [String]) -> String? {
        guard !stale.isEmpty else { return nil }
        let names = stale.map(label(for:))
        let one = names.count == 1
        let listed: String
        switch names.count {
        case 1:  listed = names[0]
        case 2:  listed = "\(names[0]) and \(names[1])"
        default: listed = names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
        return "The \(listed) here \(one ? "was" : "were") made with an older "
             + "version of the design, so \(one ? "it does" : "they do") not match "
             + "the current one. Regenerate the day to rebuild \(one ? "it" : "them")."
    }
}
