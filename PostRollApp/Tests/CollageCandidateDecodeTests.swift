import XCTest

/// The layout gallery used to return an empty array for four structurally
/// different reasons: the day genuinely has no photos, the preset resolved to
/// zero, Python's result file could not be read, and its contents no longer
/// decoded as candidates. The view showed one sentence for all four, "Make sure
/// this day has photos assigned", which is true of the first two and actively
/// misleading for the other two: a Python-side schema change presented as a day
/// with no photos, on a day visibly full of them (#358).
///
/// Empty may now mean only what that sentence says. Every technical failure
/// throws, so the view's existing catch shows the real reason.
final class CollageCandidateDecodeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collage-candidate-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ contents: String) throws -> URL {
        let url = dir.appendingPathComponent("candidates.json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testDecodesTheCandidatesPythonWrote() throws {
        let file = try write("""
        [{"seed": 11, "path": "/tmp/a.png"}, {"seed": 22, "path": "/tmp/b.png"}]
        """)

        let candidates = try PythonBridge.decodeCollageCandidates(from: file)

        XCTAssertEqual(candidates.map(\.seed), [11, 22])
        XCTAssertEqual(candidates.first?.path, "/tmp/a.png")
    }

    func testAMissingResultFileIsAFailureRatherThanNoCandidates() {
        let absent = dir.appendingPathComponent("never-written.json")

        XCTAssertThrowsError(try PythonBridge.decodeCollageCandidates(from: absent)) { error in
            XCTAssertFalse(Self.readsAsNoPhotos(error),
                           "a result file that never arrived must not be reported as a day with no photos")
        }
    }

    func testAResultFileThatNoLongerDecodesIsAFailure() throws {
        // What a rename on the Python side looks like from here.
        let file = try write("""
        [{"seed": 11, "image_path": "/tmp/a.png"}]
        """)

        XCTAssertThrowsError(try PythonBridge.decodeCollageCandidates(from: file)) { error in
            XCTAssertFalse(Self.readsAsNoPhotos(error))
        }
    }

    func testOutrightGarbageIsAFailure() throws {
        let file = try write("not json at all")

        XCTAssertThrowsError(try PythonBridge.decodeCollageCandidates(from: file))
    }

    func testAnEmptyListIsAFailureBecauseThePhotosWereAlreadyProven() throws {
        // The no-photos branches return before Python is ever run, so reaching
        // this point means photos existed and the generator produced nothing.
        // That is a broken run, not an empty day.
        let file = try write("[]")

        XCTAssertThrowsError(try PythonBridge.decodeCollageCandidates(from: file))
    }

    /// The sentence the view shows for a genuinely empty result. No technical
    /// failure may end up wearing it.
    private static func readsAsNoPhotos(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("photos assigned")
    }
}
