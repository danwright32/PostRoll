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
}
