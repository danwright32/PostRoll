import XCTest

/// #445: a failed write must not have already destroyed the file it replaces.
///
/// The program PDF download deleted the destination Dan picked in a save panel
/// and then copied. A failure between the two, a full disk or a source that had
/// gone, left him with neither the old file nor the new one, at a path he chose
/// himself and which could be anything on his disk (L5).
final class SafeFileSwapTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testItWritesWhereThereWasNothing() throws {
        let destination = dir.appendingPathComponent("new.pdf")

        try SafeFileSwap.install(Data("fresh".utf8), at: destination)

        XCTAssertEqual(try read(destination), "fresh")
    }

    func testItReplacesWhatWasThere() throws {
        let destination = try write("old", to: "existing.pdf")

        try SafeFileSwap.install(Data("new".utf8), at: destination)

        XCTAssertEqual(try read(destination), "new")
    }

    func testACopyReplacesWhatWasThere() throws {
        let source = try write("the program", to: "source.pdf")
        let destination = try write("dan's tax return", to: "chosen.pdf")

        try SafeFileSwap.install(copyOf: source, at: destination)

        XCTAssertEqual(try read(destination), "the program")
    }

    /// The whole point. A source that is not there must cost the copy and
    /// nothing else.
    func testAFailedCopyLeavesTheExistingFileExactlyAsItWas() throws {
        let destination = try write("dan's tax return", to: "chosen.pdf")
        let missing = dir.appendingPathComponent("not-here.pdf")

        XCTAssertThrowsError(try SafeFileSwap.install(copyOf: missing, at: destination))

        XCTAssertEqual(try read(destination), "dan's tax return",
                       "a failed copy had already destroyed the file it was replacing")
    }

    func testAFailedCopyLeavesNoDebrisBesideTheDestination() throws {
        let destination = try write("dan's tax return", to: "chosen.pdf")
        let missing = dir.appendingPathComponent("not-here.pdf")

        try? SafeFileSwap.install(copyOf: missing, at: destination)

        // Including the dotfiles: the temp is hidden, and a hidden half-written
        // file beside the real one is still debris (L114).
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left.sorted(), ["chosen.pdf"], "left behind: \(left)")
    }

    func testItCreatesTheDestinationDirectory() throws {
        let destination = dir.appendingPathComponent("nested/deeper/out.pdf")

        try SafeFileSwap.install(Data("x".utf8), at: destination)

        XCTAssertEqual(try read(destination), "x")
    }

    func testASuccessfulSwapLeavesNoTemporaryFile() throws {
        let destination = try write("old", to: "existing.pdf")

        try SafeFileSwap.install(Data("new".utf8), at: destination)

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left.sorted(), ["existing.pdf"], "left behind: \(left)")
        XCTAssertEqual(try read(destination), "new")
    }
}
