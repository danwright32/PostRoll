import XCTest

/// #224: the guard's own inputs, exercised against a directory this test owns.
///
/// The flake that produced this issue was the import guard reading whatever was
/// in `Tests/` at that instant. These pin the boundary that fixes it: a file the
/// project does not compile cannot fail the import guard, and a file it does
/// compile still can.
final class TestSourceInventoryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ body: String) throws {
        try Data(body.utf8).write(to: dir.appendingPathComponent(name))
    }

    func testAFileTheProjectCompilesIsChecked() throws {
        let needle = "@testable import " + "PostRoll"
        try write("Real.swift", "import XCTest\n\(needle)\n")

        let offenders = TestSourceInventory.offenders(
            in: dir, registered: ["Real.swift"], containing: needle, excluding: "Guard.swift")

        XCTAssertEqual(offenders, ["Real.swift"])
    }

    func testAStrayFileTheProjectDoesNotCompileCannotFailTheGuard() throws {
        // The flake: something else writing into the directory while the guard
        // ran. A file the bundle does not compile cannot break the bundle.
        let needle = "@testable import " + "PostRoll"
        try write("Real.swift", "import XCTest\n")
        try write("Scratch.swift.bak.swift", needle)

        let offenders = TestSourceInventory.offenders(
            in: dir, registered: ["Real.swift"], containing: needle, excluding: "Guard.swift")

        XCTAssertTrue(offenders.isEmpty, "a file nobody compiles cannot break the build")
    }

    func testAFileThatDisappearsMidRunIsNotAnOffender() throws {
        // Registered but unreadable right now: absence is not evidence of the
        // forbidden import, and guessing either way is worse than saying no.
        let needle = "@testable import " + "PostRoll"

        let offenders = TestSourceInventory.offenders(
            in: dir, registered: ["Vanished.swift"], containing: needle, excluding: "Guard.swift")

        XCTAssertTrue(offenders.isEmpty)
    }

    func testItReadsFileNamesOutOfTheGeneratedProject() {
        let pbxproj = """
        /* Begin PBXBuildFile section */
        A1 /* AudioPreviewPlayerTests.swift in Sources */ = {isa = PBXBuildFile; };
        A2 /* Layout_Sidecar-Tests.swift in Sources */ = {isa = PBXBuildFile; };
        /* End PBXBuildFile section */
        """
        let names = TestSourceInventory.registeredNames(inProject: pbxproj)
        XCTAssertEqual(names, ["AudioPreviewPlayerTests.swift", "Layout_Sidecar-Tests.swift"])
    }

    func testAnEmptyProjectYieldsNoNamesRatherThanEverything() {
        // The failure direction that matters: an unparsed project must not
        // silently mean "check nothing", which is why the guard also asserts a
        // floor on the count.
        XCTAssertTrue(TestSourceInventory.registeredNames(inProject: "").isEmpty)
    }
}
