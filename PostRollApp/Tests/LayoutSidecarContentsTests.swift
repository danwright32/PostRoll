import XCTest

/// #160: a cached collage says which design made it.
///
/// Rendered collages are cached per day, and when the design changed (gallery
/// mat, caption plate, shape-aware layout) every existing collage kept
/// rendering the old look indefinitely until somebody happened to regenerate
/// that day. Nothing surfaced them as out of date.
///
/// The tolerance for the old shape matters as much as the stamp: every collage
/// rendered before this has a bare-array sidecar, and treating those as
/// unreadable would blank a day's crop editing rather than badge it.
final class LayoutSidecarContentsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws -> URL {
        let url = dir.appendingPathComponent("collage_layout.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private let oneCell = #"{"photo_path": "/p/a.jpg", "x": 0, "y": 0, "w": 10, "h": 10}"#

    func testAStampedSidecarReportsItsVersionAndCells() throws {
        let url = try write(#"{"version": \#(CollageDesign.collageDesignVersion), "cells": [\#(oneCell)]}"#)

        let contents = LayoutSidecar.read(at: url)

        XCTAssertEqual(contents.version, CollageDesign.collageDesignVersion)
        XCTAssertEqual(contents.cells.count, 1)
        XCTAssertFalse(contents.isStale)
    }

    func testASidecarFromAnOlderDesignIsStale() throws {
        let url = try write(#"{"version": 0, "cells": [\#(oneCell)]}"#)
        XCTAssertTrue(LayoutSidecar.read(at: url).isStale)
    }

    func testTheOldBareArrayShapeStillYieldsItsCells() throws {
        // Every collage rendered before the stamp existed. Losing these cells
        // would blank the day's crop editing, which is worse than the staleness
        // it is being read for.
        let url = try write("[\(oneCell)]")

        let contents = LayoutSidecar.read(at: url)

        XCTAssertEqual(contents.cells.count, 1)
        XCTAssertNil(contents.version,
                     "not knowing which design made something is a different "
                     + "fact from knowing it was the first one")
        XCTAssertTrue(contents.isStale, "an unstamped collage predates the stamp")
    }

    func testAMissingSidecarIsNotAnError() {
        let contents = LayoutSidecar.read(at: dir.appendingPathComponent("never.json"))
        XCTAssertTrue(contents.cells.isEmpty)
        XCTAssertNil(contents.version)
    }

    func testACorruptSidecarIsNotAnError() throws {
        let url = try write("{not json")
        XCTAssertTrue(LayoutSidecar.read(at: url).cells.isEmpty)
    }

    func testItFindsTheSidecarFromThePreviewItBelongsTo() throws {
        _ = try write(#"{"version": 9, "cells": []}"#)
        let preview = dir.appendingPathComponent("collage.png")
        XCTAssertEqual(LayoutSidecar.read(forPreview: preview).version, 9)
    }

    /// The stale badge must not re-read the file on every redraw.
    ///
    /// The first version of it checked the sidecar inside the view body, so it
    /// opened and parsed a file every time that row redrew, for an answer that
    /// only changes when the day is regenerated. The export screen had taken
    /// the cached shape an hour earlier for exactly this reason (#247).
    ///
    /// Checked structurally rather than by building the view: what is guarded
    /// is that the answer comes from stored state and the read happens in a
    /// named refresh, not in `body`.
    ///
    /// Read from the ONE file that owns the badge rather than from the caption
    /// review sources as a set. The pair below (a named refresh, and something
    /// calling it) is satisfied by two unrelated files if the text is read as
    /// one body, which would prove neither half (L178, L135). The strip moved
    /// out of `CaptionReviewView.swift` when the screen was split (#741).
    /// The body of the first `.onAppear { ... }` in `source`, braces matched.
    ///
    /// Enough for the shape these views are written in, and it fails in the SAFE
    /// direction: an unbalanced read returns everything after the handler, which
    /// can only make the assertion easier to satisfy, and the assertion beside
    /// it would then be the thing to distrust rather than this.
    private static func appearHandler(in source: String) -> String {
        guard let start = source.range(of: ".onAppear {") else { return "" }
        var depth = 0
        var out = ""
        for char in source[start.upperBound...] {
            if char == "{" { depth += 1 }
            if char == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            out.append(char)
        }
        return out
    }

    func testTheReviewScreenReadsTheStampOnceRatherThanEveryRedraw() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/CaptionReview/ReviewMediaStrip.swift"),
            encoding: .utf8)

        // #286 widened this from the collage to every template the day cached,
        // so the state holds a list rather than a flag, but the shape it is
        // guarding is unchanged.
        XCTAssertTrue(source.contains("@State private var staleTemplates"),
                      "the staleness answer is not held in state, so it is being "
                      + "recomputed rather than remembered")
        // The defect's exact shape: the read used as the branch condition, so
        // it runs whenever SwiftUI evaluates the view. The file's other reads
        // are legitimate; they load the cells on a background task keyed on the
        // preview, which is off the redraw path.
        XCTAssertFalse(source.contains("if LayoutSidecar.read("),
                       "the sidecar is being read to decide whether to draw the "
                       + "badge, which puts a file read back on every redraw")
        XCTAssertFalse(source.contains("if DesignStamp.staleTemplates("),
                       "the day folder is being scanned to decide whether to draw "
                       + "the badge, which puts a directory listing on every redraw")
        XCTAssertTrue(source.contains("private func refreshDesignStaleness()"),
                      "the read has no named home to be called from")
        // And it is actually called back when the answer can have changed.
        //
        // Asserted as the CALL being inside the appear handler, not as the exact
        // one line rendering of it. The first version pinned
        // `.onAppear { refreshDesignStaleness() }` character for character and
        // went red the moment a second refresh was added beside it in #1117,
        // which is a guard defending a spelling rather than a rule (L103).
        XCTAssertTrue(Self.appearHandler(in: source).contains("refreshDesignStaleness()"),
                      "the staleness is not refreshed when the row appears, so "
                      + "the badge shows whatever the last day left behind")
        XCTAssertTrue(source.contains("onChange(of: graphicVersion)"),
                      "a finished regeneration rewrites the stamp, so the badge "
                      + "must clear without leaving the screen")
    }
}
