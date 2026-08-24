import XCTest

/// The state the hand check seeds is one the APP can read (#879).
///
/// `tests/test_hand_check_states.py` holds `hand-check.sh seeded` to writing the
/// JSON it promises. That is a check on the shape of a file, taken by something
/// that will never load it: it can be green on a store the app throws out on
/// launch, because the store's reader is `JSONDecoder().decode([Event].self)`
/// and only Swift has that.
///
/// The distance between those two is not hypothetical. `Event.date` is written
/// as a number of seconds since 2001, because `EventStore` decodes with a plain
/// decoder; an ISO string there is valid JSON, passes every assertion on the
/// Python side, and makes the whole store undecodable. The state built to be
/// healthy would then raise the corrupt store alert instead, and whoever was
/// following the Dock step would be looking at a screen belonging to a
/// different one.
///
/// So this decodes what the script wrote, the way the app does, and asks the
/// three questions that decide whether a generation can be started from it.
final class HandCheckSeededStoreTests: XCTestCase {

    private var world: URL!
    private var shoot: URL!

    override func setUpWithError() throws {
        world = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandCheckSeeded-\(UUID().uuidString)")
        shoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandCheckShoot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        // Matched by name, so the bytes do not have to be a photograph. What is
        // under test is the store, not the pipeline.
        for index in 1...3 {
            try Data("stand-in for a photograph".utf8)
                .write(to: shoot.appendingPathComponent("DSC000\(index).JPG"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: world)
        try? FileManager.default.removeItem(at: shoot)
    }

    /// Run the script the checklist runs, in a world of this test's own.
    @discardableResult
    private func seed() throws -> [Event] {
        let script = RepoFixture.repoRoot()
            .appendingPathComponent("PostRollApp/hand-check.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "seeded", shoot.path, "--no-launch"]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["POSTROLL_HAND_CHECK_WORLD": world.path]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)
        process.waitUntilExit()

        // The seeding has to be reported as having HAPPENED before anything is
        // asserted about what it produced, or a script that refused reads as an
        // app that writes no events (L98).
        XCTAssertEqual(process.terminationStatus, 0,
                       "hand-check.sh seeded failed, so nothing below is about a "
                       + "seeded world:\n\(said)")

        let store = world.appendingPathComponent("data/events.json")
        let data = try Data(contentsOf: store)
        return try JSONDecoder().decode([Event].self, from: data)
    }

    func testTheSeededStoreDecodesAsExactlyOneEvent() throws {
        let events = try seed()

        XCTAssertEqual(events.count, 1,
                       "the seeded store decoded as \(events.count) events. One is "
                       + "what step 8 opens without having to choose")
    }

    func testTheSeededEventIsAtTheStageWhoseScreenIsTheGenerationScreen() throws {
        let event = try XCTUnwrap(try seed().first)

        // EventDetailView shows AssetGenerationView for this stage and a
        // different screen for every other one, so a seeded event at the wrong
        // stage leaves the button in step 8 on a screen nobody can reach.
        XCTAssertEqual(event.stage, .photosAssigned,
                       "the seeded event is at \(event.stage.rawValue), so the app "
                       + "does not show it the generation screen")
    }

    func testTheSeededEventCarriesAnOCRResultTheManifestCanBeBuiltFrom() throws {
        let event = try XCTUnwrap(try seed().first)

        // `PythonBridge.buildManifest` throws "No OCR result" before the
        // pipeline is started at all. Without one, the only outcome step 8 can
        // reach is the failure banner, and its successful half is unreachable
        // while looking exactly like a run that was set up properly.
        let ocr = try XCTUnwrap(event.ocrResult,
                                "the seeded event has no OCR result, so every run "
                                + "started from it fails before the pipeline runs")
        XCTAssertFalse(ocr.performers.isEmpty,
                       "the seeded programme names nobody, so the captions have "
                       + "nothing to be about")
    }

    func testTheSeededDayCarriesPhotosThatAreActuallyThere() throws {
        let event = try XCTUnwrap(try seed().first)

        let monday = try XCTUnwrap(event.days[DayName.monday.rawValue],
                                   "the seeded event has no Monday, so there is no "
                                   + "day with photos on it")
        XCTAssertEqual(monday.photoPaths.count, 3,
                       "the seeded day carries \(monday.photoPaths.count) photos "
                       + "rather than the three it was given")

        // Through the file system, not the string. `Generate All` is enabled by
        // the COUNT of paths, so a day full of URLs naming nothing gets the
        // button pressed and the run fails on the first read.
        for photo in monday.photoPaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path),
                          "\(photo.path) is named by the seeded event and is not there")
        }
    }
}
