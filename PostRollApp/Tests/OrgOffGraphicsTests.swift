import XCTest

/// An organisation named and tagged in the captions but left off the graphics.
///
/// Dan sometimes shoots for an organisation he wants tagged but not printed on
/// the story plates, collages and reels. Before this, the only way to keep it
/// off the graphics was to leave the organisation blank, and a blank
/// organisation also hides the Organization handle row (#689), because the
/// handle book is keyed by the organisation's name. So the name stays on the
/// event and a switch decides whether the graphics are given it.
final class OrgOffGraphicsTests: XCTestCase {

    private func pianoPiano(offGraphics: Bool, rendered: Bool = false) -> Event {
        var ev = Event(name: "Spring Recital", org: "Lyric Collective", venue: "Piano Piano",
                       date: Date(timeIntervalSince1970: 1_789_000_000), shootType: .fullShow)
        ev.orgOffGraphics = offGraphics
        ev.ocrResult = OCRResult(performers: [])
        if rendered {
            ev.previewMediaPaths = ["sunday": ["story": "/s.png"],
                                    "wednesday": ["collage": "/c.png"]]
            ev.days["wednesday"] = PostingDay(day: .wednesday)
            ev.previewMediaPaths["wednesday"]?["cover"] = "/cover.png"
        }
        return ev
    }

    // MARK: - The store

    func testAnEventStoredBeforeThisPrintsItsOrganisation() throws {
        let ev = pianoPiano(offGraphics: false)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ev)) as? [String: Any])
        json.removeValue(forKey: "orgOffGraphics")

        let back = try JSONDecoder().decode(
            Event.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertFalse(back.orgOffGraphics)
        XCTAssertEqual(back.graphicsOrg, "Lyric Collective")
    }

    func testTheSwitchSurvivesTheStore() throws {
        let back = try JSONDecoder().decode(
            Event.self, from: JSONEncoder().encode(pianoPiano(offGraphics: true)))

        XCTAssertTrue(back.orgOffGraphics)
    }

    // MARK: - What each render is given

    func testTheMediaRunIsGivenNoOrganisationWhenItIsOffTheGraphics() {
        let hidden = PythonBridge.shared.buildMediaManifest(event: pianoPiano(offGraphics: true))
        let shown = PythonBridge.shared.buildMediaManifest(event: pianoPiano(offGraphics: false))

        XCTAssertEqual(hidden["org"] as? String, "")
        XCTAssertEqual(shown["org"] as? String, "Lyric Collective")
    }

    func testTheCoverIsGivenNoOrganisationWhenItIsOffTheGraphics() throws {
        let manifest = try XCTUnwrap(PythonBridge.buildCoverManifest(
            event: pianoPiano(offGraphics: true, rendered: true),
            day: .wednesday, overrideSource: nil))

        XCTAssertEqual(manifest["org"] as? String, "")
    }

    func testTheCollageGalleryIsGivenNoOrganisationWhenItIsOffTheGraphics() {
        let args = PythonBridge.graphicsTextArgs(for: pianoPiano(offGraphics: true))

        XCTAssertEqual(args, ["--event", "Spring Recital", "--org", "", "--venue", "Piano Piano"])
    }

    func testTheCaptionsStillNameTheOrganisation() throws {
        // Tagging it is the whole point, and the caption writer is told the
        // organisation it is tagging.
        let manifest = try PythonBridge.shared.buildManifest(event: pianoPiano(offGraphics: true))

        XCTAssertEqual(manifest["org"] as? String, "Lyric Collective")
    }

    func testOnlyCaptionAndBlogBuildersReadTheOrganisationDirectly() throws {
        // Every graphics render goes through `graphicsOrg`. A new render that
        // reads `event.org` itself would print an organisation Dan asked to
        // keep off, with nothing failing, so any direct read outside the
        // writers that are meant to name it fails here and asks which it is.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Services/PythonBridge.swift")
        let code = SwiftSourceText.withoutComments(try String(contentsOf: url, encoding: .utf8))
        let writers: Set<String> = [
            "buildCaptionRevisionManifest", "buildBlogRevisionManifest",
            "buildBlogPhotoSwapManifest", "buildManifest",
        ]

        var enclosing = ""
        var readers: [String] = []
        for line in code.components(separatedBy: "\n") {
            if let range = line.range(of: #"func\s+(\w+)"#, options: .regularExpression) {
                enclosing = String(line[range]).replacingOccurrences(
                    of: #"func\s+"#, with: "", options: .regularExpression)
            }
            if line.range(of: #"\bevent\.org\b"#, options: .regularExpression) != nil {
                readers.append(enclosing)
            }
        }

        XCTAssertFalse(readers.isEmpty, "the scan found no reads at all, so it is reading the wrong file")
        XCTAssertEqual(Set(readers).subtracting(writers), [],
                       "these read event.org directly; a graphics render must use graphicsOrg")
    }

    // MARK: - Edit Details

    func testTurningTheSwitchOnRedrawsEveryRenderedDay() {
        let before = pianoPiano(offGraphics: false, rendered: true)
        let after = NewEventForm.edited(before, name: before.name, org: before.org,
                                        venue: before.venue, venueContext: before.venueContext,
                                        orgOffGraphics: true, shootType: before.shootType)

        let saved = EventDetailsSave(before: before, after: after)

        XCTAssertTrue(after.orgOffGraphics)
        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.refreshDays, [.sunday, .wednesday])
    }

    func testRenamingAnOrganisationOffTheGraphicsRedrawsNothing() {
        // The graphics never printed it, so there is no old text to replace.
        let before = pianoPiano(offGraphics: true, rendered: true)
        let after = NewEventForm.edited(before, name: before.name, org: "Lyric Collective NYC",
                                        venue: before.venue, venueContext: before.venueContext,
                                        orgOffGraphics: true, shootType: before.shootType)

        let saved = EventDetailsSave(before: before, after: after)

        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.refreshDays, [])
    }

    func testClearingTheOrganisationTurnsTheSwitchOff() {
        // Otherwise a switch left on under a cleared name would quietly keep
        // the next organisation typed in off the graphics.
        let before = pianoPiano(offGraphics: true, rendered: true)
        let cleared = NewEventForm.edited(before, name: before.name, org: "  ",
                                          venue: before.venue, venueContext: before.venueContext,
                                          orgOffGraphics: true, shootType: before.shootType)
        let created = NewEventForm.event(name: "Spring Recital", org: "", venue: "", venueContext: "",
                                         date: Date(timeIntervalSince1970: 0), shootType: .fullShow,
                                         bookingID: nil, orgOffGraphics: true)

        XCTAssertFalse(cleared.orgOffGraphics)
        XCTAssertFalse(created.orgOffGraphics)
        XCTAssertTrue(EventDetailsSave(before: before, after: cleared).changed)
    }

    func testCreateCarriesTheSwitch() {
        let ev = NewEventForm.event(name: "Spring Recital", org: "Lyric Collective",
                                    venue: "Piano Piano", venueContext: "",
                                    date: Date(timeIntervalSince1970: 0), shootType: .fullShow,
                                    bookingID: nil, orgOffGraphics: true)

        XCTAssertTrue(ev.orgOffGraphics)
    }
}
