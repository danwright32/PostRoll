import XCTest

/// #107: the presets are stated once in `tests/fixtures/posting_presets.json`,
/// and both implementations assert against that same file.
///
/// Before this, `postroll/posting_preset.py` was the declared source of truth
/// with no direct tests, while only this Swift mirror was pinned. The source
/// could therefore change and only the copy would complain, which is backwards.
/// Sharing the fixture means neither side can drift without somebody editing
/// the fixture deliberately.
final class PostingPresetSharedFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let preset: String
            let day: String
            let format: String?
            let count: Int?
        }
        let default_preset: String
        let cases: [Case]
        let unknown_preset_falls_back_to_default: [Case]
    }

    /// Located from this file, not a bundle resource: the test target has no
    /// resource phase, and a copied fixture would be a second copy able to
    /// drift from the one Python reads, which is the whole thing being fixed.
    private func loadFixture() throws -> Fixture {
        return try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/posting_presets.json"))
    }

    private func day(named name: String) -> DayName? {
        DayName.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    /// The wire strings Python uses. Mapped here rather than added to the enum
    /// as a rawValue: DayFormat is never serialised, so a rawValue would exist
    /// only for the test and could then be wrong without anything noticing.
    private func wireName(_ format: DayFormat) -> String {
        switch format {
        case .single:          return "single"
        case .collageCarousel: return "collage_carousel"
        }
    }

    private func preset(named name: String) -> PostingPreset {
        PostingPreset(rawValue: name) ?? .balanced
    }

    func testTheFixtureIsReadable() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty, "an empty fixture would assert nothing")
    }

    func testTheDefaultPresetMatchesTheFixture() throws {
        XCTAssertEqual(PostingPreset.balanced.rawValue, try loadFixture().default_preset)
    }

    func testEveryFixtureCaseMatchesTheSwiftMirror() throws {
        let fixture = try loadFixture()
        for c in fixture.cases {
            guard let day = day(named: c.day) else {
                return XCTFail("fixture names a day Swift does not have: \(c.day)")
            }
            let result = preset(named: c.preset).format(for: day)
            if let expectedFormat = c.format, let expectedCount = c.count {
                XCTAssertEqual(result.map { wireName($0.format) }, expectedFormat,
                               "\(c.preset)/\(c.day)")
                XCTAssertEqual(result?.count, expectedCount, "\(c.preset)/\(c.day)")
            } else {
                XCTAssertNil(result,
                             "\(c.day) is not governed by the preset, so it must be nil")
            }
        }
    }

    func testIsCollageCarouselAgreesWithTheFixture() throws {
        for c in try loadFixture().cases {
            guard let day = day(named: c.day) else { continue }
            XCTAssertEqual(preset(named: c.preset).isCollageCarousel(day),
                           c.format == "collage_carousel",
                           "\(c.preset)/\(c.day)")
        }
    }

    func testAnUnknownPresetFallsBackTheSameWayPythonDoes() throws {
        for c in try loadFixture().unknown_preset_falls_back_to_default {
            guard let day = day(named: c.day) else { continue }
            let result = preset(named: c.preset).format(for: day)
            XCTAssertEqual(result.map { wireName($0.format) }, c.format, c.preset)
            XCTAssertEqual(result?.count, c.count, c.preset)
        }
    }
}
