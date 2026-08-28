import XCTest

/// #286: every cached template says which design made it, not just the collage.
///
/// #160 stamped the collage, carried in the layout sidecar that already sat
/// beside its PNG. The reels and the stills went through the same gallery
/// redesign and got no stamp, so a cached Thursday scroll reel, Tuesday reel,
/// before/after or story from before it keeps rendering the old look with
/// nothing saying so. The reels are the worst case, because re-rendering one is
/// expensive enough that nobody does it speculatively.
///
/// The reading side of `postroll/media/design_stamp.py`. What matters most here
/// is the shape of the answer for a day folder with NO stamp: every day folder
/// on disk today is in exactly that state, and reading it as current would
/// leave the defect this was written to fix in place.
final class DesignStampTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Put an asset on disk for each named template, as a render would.
    private func cache(_ names: String...) throws {
        for name in names {
            let ext = name.hasPrefix("reel_") && name != "reel_preview" ? "mp4" : "png"
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(name).\(ext)"))
        }
    }

    /// Set a cached asset's modification date, as an old render would have it.
    private func age(_ name: String, to day: String) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let when = try XCTUnwrap(formatter.date(from: day)).addingTimeInterval(12 * 3600)
        let found = try FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)
            .first { $0.deletingPathExtension().lastPathComponent == name }
        try FileManager.default.setAttributes([.modificationDate: when],
                                              ofItemAtPath: try XCTUnwrap(found).path)
    }

    /// A template whose design has actually changed, taken from the table
    /// rather than typed here, so these follow the versions (L41).
    private var bumped: String {
        get throws { try XCTUnwrap(MediaDesign.mediaDesignChanged.keys.sorted().first) }
    }

    /// The day before `name`'s design last changed.
    private func dayBefore(_ name: String) throws -> String {
        let changed = try XCTUnwrap(MediaDesign.mediaDesignChanged[name])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = try XCTUnwrap(formatter.date(from: changed))
        return formatter.string(from: date.addingTimeInterval(-86400))
    }

    private func stamp(_ templates: [String: Int]) throws {
        let doc = try JSONSerialization.data(withJSONObject: ["templates": templates])
        try doc.write(to: dir.appendingPathComponent(DesignStamp.stampName))
    }

    // MARK: - The current design

    func testADayStampedWithTheCurrentDesignIsNotStale() throws {
        try cache("reel_scroll", "story")
        try stamp(["reel_scroll": MediaDesign.version(of: "reel_scroll")!,
                   "story": MediaDesign.version(of: "story")!])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testATemplateStampedOlderThanTheCurrentDesignIsStale() throws {
        try cache("reel_scroll", "story")
        try stamp(["reel_scroll": 0, "story": MediaDesign.version(of: "story")!])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), ["reel_scroll"])
    }

    func testATemplateStampedNewerThanThisBuildIsNotStale() throws {
        // Regenerating here would replace a better asset with an older design,
        // so sending Dan to do that is worse than saying nothing.
        try cache("story")
        try stamp(["story": MediaDesign.version(of: "story")! + 5])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    // MARK: - What is already on disk

    func testAnAssetWithNoRecordIsNotReported() throws {
        // The badge fires on evidence, never on the absence of it. Measured on
        // real data (2026-08-10): all 66 day folders on Dan's machine hold
        // assets and no stamp, so treating "no record" as stale badged every one
        // of them, and a badge on every day is one nobody reads (L36). They were
        // not old either: the redesign landed 2026-07-14, the newest previews
        // were rendered 2026-08-07.
        try cache("reel_scroll", "story", "collage")

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAnAssetTheStampDoesNotMentionIsNotReported() throws {
        try cache("reel_scroll", "story")
        try stamp(["story": MediaDesign.version(of: "story")!])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testARecordedAssetBesideAnUnrecordedOneIsStillCaught() throws {
        // The silence must not spread: an asset the stamp DOES vouch for, at an
        // old version, is evidence whatever its neighbours are missing.
        try cache("reel_scroll", "story")
        try stamp(["story": 0])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), ["story"])
    }

    // MARK: - An unstamped asset older than its design change (#804)

    func testAnUnstampedAssetOlderThanItsDesignChangeIsStale() throws {
        // The whole of #804, and the half the app actually runs. The colophon
        // lift bumped before_after and nothing on disk could notice: there were
        // zero stamps under the entire preview library, so the badge covered no
        // asset that existed. Dan published the 7 August render of
        // 6. Friday/before_after.png, wordmark clipped against the bottom edge,
        // and the app had no way to say so.
        let name = try bumped
        try cache(name)
        try age(name, to: try dayBefore(name))

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [name])
    }

    func testAnUnstampedAssetNewerThanItsDesignChangeIsNotStale() throws {
        // What keeps this off the rest of the library: an asset rendered after
        // the change was rendered by the current design.
        let name = try bumped
        try cache(name)

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAnUnstampedTemplateWhoseDesignNeverChangedIsNotReported() throws {
        // No bump, no claim. A template still at its first version has no
        // recorded design CHANGE, only a date somebody first wrote a number
        // down, and an asset older than that was made by the same design.
        //
        // Driven against an INJECTED table since #921. It used to read the
        // shipping one and take whatever had no change recorded, which worked
        // until the collage got one and the set went empty, at which point this
        // correctly refused to pass over nothing. A rule is tested by feeding
        // it the case (L1).
        var withoutOne = MediaDesign.mediaDesignChanged
        let never = "collage"
        XCTAssertNotNil(withoutOne.removeValue(forKey: never))

        try cache(never)
        try age(never, to: "2020-01-01")

        XCTAssertEqual(
            DesignStamp.staleTemplates(in: dir, changedDays: withoutOne), [])
    }

    func testAStampStillDecidesOverTheFileDate() throws {
        // A record beats an inference. The stamp measures what rendered the
        // day; the file date is evidence about when.
        let name = try bumped
        try cache(name)
        try age(name, to: try dayBefore(name))
        try stamp([name: MediaDesign.version(of: name)!])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAnAssetWhoseDateCannotBeReadIsNotReported() throws {
        // Unreadable is not old: reporting on it would be a claim this never
        // measured. Proven beside the positive case in the same fixture, so a
        // predicate that answered false for everything would not pass (L159).
        let name = try bumped
        XCTAssertFalse(DesignStamp.predatesItsDesignChange(
            name, at: dir.appendingPathComponent("not-here.png")))

        try cache(name)
        try age(name, to: try dayBefore(name))
        let real = try XCTUnwrap(DesignStamp.cachedAssets(in: dir)[name])
        XCTAssertTrue(DesignStamp.predatesItsDesignChange(name, at: real))
    }

    func testTheTwoHalvesAgreeOnEveryRecordedChange() throws {
        // The Swift table is what the app reads and the Python one is where the
        // reasoning lives. tests/test_media_design_version.py holds them equal;
        // this holds the Swift side to being usable at all, so a date that
        // parses to nil badges nothing while the mirror test still passes.
        for name in MediaDesign.mediaDesignChanged.keys {
            XCTAssertNotNil(MediaDesign.changed(of: name),
                            "\(name) records a design change this build cannot parse")
        }
    }

    // MARK: - The collage already had a home for this

    private func collageSidecar(_ json: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent("collage_layout.json"))
    }

    func testACollageTheOldSidecarVouchesForIsNotReported() throws {
        try cache("collage", "reel_scroll")
        try collageSidecar(#"{"version": \#(MediaDesign.version(of: "collage")!), "cells": []}"#)

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testACollageTheOldSidecarRecordsAsOlderIsStillCaught() throws {
        // The one case the sidecar fallback still earns: #160 recorded a version,
        // it is behind, and there is no day stamp because the day has not been
        // regenerated since. Dropping it would throw away a genuine detection
        // the collage already had.
        try cache("collage")
        try collageSidecar(#"{"version": 0, "cells": []}"#)

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), ["collage"])
    }

    func testACollageWhoseSidecarPredatesTheStampIsNotReported() throws {
        // A bare array is a sidecar written before #160, so it records no
        // version. No record is not evidence. Every collage on disk today.
        try cache("collage")
        try collageSidecar("[]")

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testTheDayStampWinsOverTheCollageSidecar() throws {
        try cache("collage")
        try collageSidecar(#"{"version": \#(MediaDesign.version(of: "collage")!), "cells": []}"#)
        try stamp(["collage": 0])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), ["collage"])
    }

    func testAStampedTemplateWithNoAssetOnDiskIsNotReported() throws {
        // Nothing to regenerate and nothing rendering an old look, so naming it
        // would send Dan after an asset that does not exist.
        try stamp(["story": 0])

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAFileCarryingNoDesignIsNotReported() throws {
        // Friday's cover_frame.jpg is a source photograph copied out of a temp
        // dir. Regenerating the day cannot make it look newer.
        try Data("x".utf8).write(to: dir.appendingPathComponent("cover_frame.jpg"))

        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAnEmptyDayFolderHasNothingToSay() {
        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAMissingDayFolderDoesNotThrow() {
        XCTAssertEqual(
            DesignStamp.staleTemplates(in: dir.appendingPathComponent("never rendered")), [])
    }

    // MARK: - Nothing on disk is trusted

    // An unreadable stamp is no evidence, so it is silent, like every other
    // no-record case. What is guarded here is that it does not THROW and does
    // not get believed: a corrupt file must never be decoded into a version.

    func testACorruptStampDoesNotThrowAndVouchesForNothing() throws {
        try cache("story")
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(DesignStamp.stampName))

        XCTAssertEqual(DesignStamp.read(in: dir), [:])
        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    func testAStampOfTheWrongShapeReadsAsNoRecord() throws {
        try cache("story")
        let doc = try JSONSerialization.data(withJSONObject: ["templates": "story"])
        try doc.write(to: dir.appendingPathComponent(DesignStamp.stampName))

        XCTAssertEqual(DesignStamp.read(in: dir), [:])
    }

    func testAVersionThatIsNotAWholeNumberIsDropped() throws {
        // A value that cannot be compared must never be turned into one (L50).
        // Dropped per entry, not all-or-nothing, so the good neighbour survives:
        // Python's reader drops per entry, and two readers of one file that
        // disagree about a bad value is the class of defect the pairing exists
        // to avoid (L26). `true` is in here because it answers to an integer in
        // both languages, and 1 is a plausible-looking version.
        for bad in ["1", true, 1.5, NSNull(), [1], ["v": 1]] as [Any] {
            try cache("story", "collage")
            let doc = try JSONSerialization.data(
                withJSONObject: ["templates": ["story": bad, "collage": 0]])
            try doc.write(to: dir.appendingPathComponent(DesignStamp.stampName))

            XCTAssertNil(DesignStamp.read(in: dir)["story"], "\(bad) was believed")
            XCTAssertEqual(DesignStamp.read(in: dir)["collage"], 0,
                           "\(bad) took its good neighbour down with it")
            XCTAssertEqual(DesignStamp.staleTemplates(in: dir), ["collage"], "\(bad)")
        }
    }

    // MARK: - A stamp Python actually wrote

    /// Every other test in this file builds its own JSON, and a fake you wrote
    /// can only confirm your own assumption about the real interface (L52).
    /// `tests/fixtures/design_stamp.json` is written by the real Python writer,
    /// and `tests/test_media_design_version.py` asserts it stays that way, so
    /// this is the one case where the reader meets what the writer produces.
    func testAStampPythonWroteReadsBackAsEveryTemplateBeingCurrent() throws {
        let real = try RepoFixture.data("tests/fixtures/design_stamp.json")
        try real.write(to: dir.appendingPathComponent(DesignStamp.stampName))

        XCTAssertEqual(DesignStamp.read(in: dir), MediaDesign.mediaDesignVersions,
                       "the app decodes Python's own stamp differently from the "
                       + "versions it renders, so every day would badge, or none")
    }

    func testADayHoldingEveryAssetUnderPythonsOwnStampIsNotStale() throws {
        // The end of the round trip: render a day, stamp it, and the badge stays
        // away. Vacuous unless the assets are actually there, so they are.
        let real = try RepoFixture.data("tests/fixtures/design_stamp.json")
        try real.write(to: dir.appendingPathComponent(DesignStamp.stampName))
        for name in MediaDesign.allTemplates {
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(name).png"))
        }

        XCTAssertEqual(DesignStamp.cachedTemplates(in: dir), MediaDesign.allTemplates)
        XCTAssertEqual(DesignStamp.staleTemplates(in: dir), [])
    }

    // MARK: - What the badge says

    func testTheMessageNamesTheTemplatesThatAreOutOfDate() throws {
        // Naming them is the difference between "something here is old" and a
        // sentence Dan can act on without opening anything to find out what.
        let message = try XCTUnwrap(
            DesignStamp.staleMessage(for: ["reel_scroll", "before_after"]))

        XCTAssertTrue(message.contains("scroll reel"), message)
        XCTAssertTrue(message.contains("before and after"), message)
    }

    func testTheMessageClaimsOnlyWhatWasMeasured() throws {
        // It is only reachable when a version was recorded and is behind, so
        // "older version of the design" is a measured claim rather than a guess
        // (L11). If the no-record case ever routes here, this is the wording
        // that would become a lie.
        let message = try XCTUnwrap(DesignStamp.staleMessage(for: ["reel_scroll"]))

        XCTAssertTrue(message.contains("older version of the design"), message)
    }

    func testEveryTemplateTheAppKnowsHasSomethingToCallIt() {
        // A badge naming a raw filename stem ("reel_morph is out of date") reads
        // as a bug report rather than as a sentence, and the label table is the
        // kind of thing a new template quietly misses.
        for name in MediaDesign.allTemplates {
            XCTAssertFalse(DesignStamp.label(for: name).contains("_"),
                           "\(name) has no readable label, so the badge would name the file")
        }
    }

    func testThereIsNoMessageWhenNothingIsStale() {
        XCTAssertNil(DesignStamp.staleMessage(for: []))
    }
}
