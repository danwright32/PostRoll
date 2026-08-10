import XCTest

/// #267: the layout sidecar's name is one rule, satisfied by both languages.
///
/// Python writes the file; this side reads it from the crop editor, the collage
/// thumbnail and the export compositor. Swift rebuilt the name in five separate
/// places, one of them a hardcoded `reel_preview_layout.json` literal, and
/// nothing forced them to agree.
///
/// `tests/fixtures/layout_sidecar.json` is the contract. `tests/
/// test_layout_sidecar.py` asserts the Python side satisfies the same file.
final class LayoutSidecarTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Vector: Decodable {
            let preview: String
            let sidecar: String
        }
        let suffix: String
        let vectors: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        return try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/layout_sidecar.json"))
    }

    func testSwiftSatisfiesTheSharedNamingContract() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 4,
                                    "an empty or gutted fixture would pass vacuously")
        XCTAssertEqual(LayoutSidecar.suffix, fixture.suffix)

        let dir = URL(fileURLWithPath: "/previews/wednesday")
        for v in fixture.vectors {
            XCTAssertEqual(LayoutSidecar.url(for: dir.appendingPathComponent(v.preview)),
                           dir.appendingPathComponent(v.sidecar),
                           "sidecar name for \(v.preview)")
        }
    }

    func testTheSidecarLandsBesideItsPreview() {
        let preview = URL(fileURLWithPath: "/previews/thursday/reel_preview.png")
        XCTAssertEqual(LayoutSidecar.url(for: preview).deletingLastPathComponent(),
                       preview.deletingLastPathComponent())
    }

    func testNoScreenBuildsTheNameByHand() throws {
        // The point of the helper: one derivation, not one per reader. Derived
        // from the source rather than a list written here, so a screen added
        // later is covered on the day it lands.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources,
                                                   includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "LayoutSidecar.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("_layout.json") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "these files spell the sidecar name out themselves: \(offenders)")
    }
}
