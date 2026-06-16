import XCTest

/// Regression coverage for the Wednesday collage swap that started duplicating a
/// photo instead of swapping cells. The layout JSON records the path Python used
/// at generation time, but MediaReclaim later copies that file into app storage
/// and rewrites the day's photoPaths. The dragged thumbnail then carries the new
/// (app-storage) path while the cells still hold the old (e.g. ~/Downloads) path,
/// so a swap could not find the source cell and the photo landed in the collage
/// twice. `rebasing` re-links the cells; `applyingDrop` is filename-tolerant.
final class CollageCellSwapTests: XCTestCase {

    private func cell(_ path: String, _ x: Int = 0, _ y: Int = 0, _ w: Int = 100, _ h: Int = 100) -> CollageCell {
        let json = """
        {"photo_path":"\(path)","x":\(x),"y":\(y),"w":\(w),"h":\(h)}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(CollageCell.self, from: json)
    }

    // MARK: - rebasing

    func testRebasingRelinksMovedPathsByFilename() {
        let cells = [
            cell("/Users/dan/Downloads/a.jpg"),
            cell("/Users/dan/Downloads/b.jpg"),
        ]
        let current = [
            URL(fileURLWithPath: "/Users/dan/Library/Application Support/PostRoll/photos/a.jpg"),
            URL(fileURLWithPath: "/Users/dan/Library/Application Support/PostRoll/photos/b.jpg"),
        ]
        let rebased = CollageCell.rebasing(cells, toCurrentPhotos: current)
        XCTAssertEqual(rebased.map(\.photoPath), current.map(\.path))
    }

    func testRebasingLeavesAlreadyCurrentPathsUntouched() {
        let current = [URL(fileURLWithPath: "/data/photos/a.jpg")]
        let cells = [cell("/data/photos/a.jpg")]
        XCTAssertEqual(CollageCell.rebasing(cells, toCurrentPhotos: current), cells)
    }

    func testRebasingWithNoCurrentPhotosIsIdentity() {
        let cells = [cell("/Users/dan/Downloads/a.jpg")]
        XCTAssertEqual(CollageCell.rebasing(cells, toCurrentPhotos: []), cells)
    }

    func testRebasingIgnoresFilenameWithNoCurrentMatch() {
        let cells = [cell("/old/z.jpg")]
        let current = [URL(fileURLWithPath: "/new/a.jpg")]
        // No filename match -> the cell keeps its original path rather than
        // being wrongly re-pointed at an unrelated photo.
        XCTAssertEqual(CollageCell.rebasing(cells, toCurrentPhotos: current), cells)
    }

    // MARK: - applyingDrop

    func testDropSwapsTwoCellsWithoutDuplicating() {
        let cells = [cell("/p/a.jpg", 0, 0), cell("/p/b.jpg", 0, 100)]
        // Drag b onto cell 0: a and b trade places.
        let result = CollageCell.applyingDrop(of: "/p/b.jpg", ontoCellAt: 0, in: cells)
        XCTAssertEqual(result?.map(\.photoPath), ["/p/b.jpg", "/p/a.jpg"])
        // No photo appears twice.
        XCTAssertEqual(Set(result!.map(\.photoPath)).count, 2)
    }

    func testDropOntoSameCellIsNoOp() {
        let cells = [cell("/p/a.jpg")]
        XCTAssertNil(CollageCell.applyingDrop(of: "/p/a.jpg", ontoCellAt: 0, in: cells))
    }

    func testDropMatchesSourceCellByFilenameWhenPathsDiverge() {
        // The dragged path is the new app-storage copy; the cell still holds the
        // pre-reclaim path. Filename matching must still clear the source cell so
        // the photo does not end up in the collage twice (the reported bug).
        let cells = [
            cell("/Users/dan/Downloads/a.jpg", 0, 0),
            cell("/Users/dan/Downloads/b.jpg", 0, 100),
        ]
        let dropped = "/Users/dan/Library/Application Support/PostRoll/photos/b.jpg"
        let result = CollageCell.applyingDrop(of: dropped, ontoCellAt: 0, in: cells)
        XCTAssertEqual(result?[0].photoPath, dropped)
        XCTAssertEqual(result?[1].photoPath, "/Users/dan/Downloads/a.jpg")
        // The duplicated "b.jpg" must be gone: no two cells share a filename.
        let names = result!.map { ($0.photoPath as NSString).lastPathComponent }
        XCTAssertEqual(Set(names).count, 2)
    }

    func testDropOfBrandNewPhotoReplacesTargetCell() {
        // Dropping a photo not already in the collage simply replaces the target
        // cell (no source cell to clear), and must not crash or duplicate.
        let cells = [cell("/p/a.jpg", 0, 0), cell("/p/b.jpg", 0, 100)]
        let result = CollageCell.applyingDrop(of: "/p/c.jpg", ontoCellAt: 0, in: cells)
        XCTAssertEqual(result?.map(\.photoPath), ["/p/c.jpg", "/p/b.jpg"])
    }

    func testDropOnOutOfRangeIndexIsNil() {
        let cells = [cell("/p/a.jpg")]
        XCTAssertNil(CollageCell.applyingDrop(of: "/p/b.jpg", ontoCellAt: 5, in: cells))
    }
}
