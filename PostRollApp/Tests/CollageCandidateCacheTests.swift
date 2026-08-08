import XCTest

/// Regression cover for the collage layout-gallery cache (issues #60/#61/#64):
/// it must return cached candidates only when the fingerprint matches AND the
/// files still exist, and storing a new set must delete the prior set's temp
/// directory so the gallery never leaks directories.
@MainActor
final class CollageCandidateCacheTests: XCTestCase {

    private var root: URL!

    // The async form of setUp/tearDown, deliberately: these touch main-actor
    // state (the shared cache), and the two Xcode versions in play disagree
    // about the throwing form. One rejects a @MainActor override of the
    // nonisolated `setUpWithError`, the other rejects touching main-actor state
    // without one. The async override inherits the class's isolation on both.
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("collage-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Each test starts from a clean cache for the days it touches.
        for day in DayName.allCases { CollageCandidateCache.shared.remove(day: day) }
    }

    override func tearDown() async throws {
        for day in DayName.allCases { CollageCandidateCache.shared.remove(day: day) }
        try? FileManager.default.removeItem(at: root)
    }

    /// Create a candidate set in its own directory with real PNG-ish files.
    private func makeSet(_ seeds: [Int], dirName: String) -> [CollageCandidate] {
        let dir = root.appendingPathComponent(dirName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return seeds.map { seed in
            let url = dir.appendingPathComponent("candidate_\(seed).png")
            FileManager.default.createFile(atPath: url.path, contents: Data("img".utf8))
            return CollageCandidate(seed: seed, path: url.path)
        }
    }

    func testReturnsCachedWhenFingerprintMatchesAndFilesExist() {
        let set = makeSet([1, 2, 3], dirName: "a")
        CollageCandidateCache.shared.store(day: .sunday, fingerprint: "fp-a", candidates: set)

        let hit = CollageCandidateCache.shared.cached(day: .sunday, fingerprint: "fp-a")
        XCTAssertEqual(hit, set)
    }

    func testMissesWhenFingerprintDiffers() {
        let set = makeSet([1, 2], dirName: "b")
        CollageCandidateCache.shared.store(day: .sunday, fingerprint: "fp-a", candidates: set)

        XCTAssertNil(CollageCandidateCache.shared.cached(day: .sunday, fingerprint: "fp-different"))
    }

    func testMissesAndEvictsWhenFilesVanish() {
        let set = makeSet([1, 2], dirName: "c")
        CollageCandidateCache.shared.store(day: .monday, fingerprint: "fp", candidates: set)
        // Simulate the OS clearing the temp dir out from under the cache.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("c"))

        XCTAssertNil(CollageCandidateCache.shared.cached(day: .monday, fingerprint: "fp"))
        // The stale entry was dropped, so a matching fingerprint still misses.
        XCTAssertNil(CollageCandidateCache.shared.cached(day: .monday, fingerprint: "fp"))
    }

    func testStoringNewSetDeletesPreviousDirectory() {
        let first = makeSet([1, 2, 3], dirName: "first")
        CollageCandidateCache.shared.store(day: .wednesday, fingerprint: "fp1", candidates: first)
        let firstDir = root.appendingPathComponent("first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstDir.path))

        // A new render for the same day supersedes the old set.
        let second = makeSet([4, 5, 6], dirName: "second")
        CollageCandidateCache.shared.store(day: .wednesday, fingerprint: "fp2", candidates: second)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDir.path),
                       "the superseded candidate directory must be deleted (no temp leak)")
        XCTAssertEqual(CollageCandidateCache.shared.cached(day: .wednesday, fingerprint: "fp2"), second)
    }

    func testRemoveDeletesDirectoryAndEntry() {
        let set = makeSet([7, 8], dirName: "rm")
        CollageCandidateCache.shared.store(day: .sunday, fingerprint: "fp", candidates: set)
        let dir = root.appendingPathComponent("rm")

        CollageCandidateCache.shared.remove(day: .sunday)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(CollageCandidateCache.shared.cached(day: .sunday, fingerprint: "fp"))
    }
}
