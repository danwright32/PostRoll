import XCTest

/// The layout gallery passes Dan's saved per-photo crops to Python so the
/// option thumbnails match what the final collage will look like (#62).
///
/// The argument naming that file used to be appended whether or not the write
/// behind it succeeded, because the write sat behind `try?`. Python then reads
/// that path unguarded, so a failed write reached Dan as a FileNotFoundError
/// traceback about a temp file rather than as anything about his crops (#360).
///
/// Refusing rather than carrying on is deliberate: options rendered without his
/// crops look like real options, and he would pick a layout off thumbnails that
/// do not match what gets exported.
final class CropOffsetsArgumentTests: XCTestCase {

    private var dir: URL!
    private var cropFile: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-offsets-arg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cropFile = dir.appendingPathComponent("crops.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testAllDefaultOffsetsPassNothingAndWriteNothing() throws {
        let offsets = [[0.0, 0.0, 1.0], [0.0, 0.0, 1.0]]

        let args = try PythonBridge.cropOffsetsArgument(offsets: offsets, writingTo: cropFile)

        XCTAssertTrue(args.isEmpty, "a day nobody cropped has nothing to hand over")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cropFile.path))
    }

    func testACroppedDayNamesTheFileItJustWrote() throws {
        let offsets = [[0.0, -1.0, 1.0], [0.0, 0.0, 1.0]]

        let args = try PythonBridge.cropOffsetsArgument(offsets: offsets, writingTo: cropFile)

        XCTAssertEqual(args, ["--crop-offsets-json", cropFile.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cropFile.path),
                      "the argument may only name a file that is actually there")

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: cropFile)) as? [[Double]]
        XCTAssertEqual(written, offsets)
    }

    func testAZoomAloneCountsAsACrop() throws {
        let args = try PythonBridge.cropOffsetsArgument(
            offsets: [[0.0, 0.0, 1.4]], writingTo: cropFile)

        XCTAssertEqual(args.first, "--crop-offsets-json")
    }

    func testAWriteThatCannotHappenRefusesRatherThanNamingAMissingFile() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: dir.path),
                       "precondition: the directory has to be genuinely unwritable")

        XCTAssertThrowsError(
            try PythonBridge.cropOffsetsArgument(offsets: [[0.0, -1.0, 1.0]], writingTo: cropFile)
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.lowercased().contains("crop"),
                          "the refusal has to be about his crops, not about a temp file: \(message)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: cropFile.path))
    }
}
