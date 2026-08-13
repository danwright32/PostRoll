import XCTest

/// #476: the revision manifest carries the credit inputs the week manifest does.
///
/// The hashtag gate (#199) decides whether a name may become a hashtag from
/// four inputs: the programme, the plain-name credits, the per-photo people
/// tags, and the handles offered for mentioning. The revision manifest sent
/// only the programme, so a person Dan credited by name or tagged on a photo
/// could keep a hashtag on a revision that the generation pass would have
/// stripped, and the credit checks (#475) had no tag list to judge against at
/// all.
///
/// One derivation for both manifests rather than two. The two would drift, and
/// the drift is silent: a handle offered for generation but not for revision
/// reads to the checks as a handle nobody offered, which is the finding that
/// says a caption tags a stranger.
final class CaptionCreditInputsTests: XCTestCase {

    private func event() -> Event {
        var event = Event(name: "Spring Concert", org: "Every Voice Choirs",
                          venue: "Carnegie Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var ocr = OCRResult()
        ocr.performers = [
            Performer(id: UUID(), name: "A Singer", role: "Soprano",
                      voiceOrInstrument: "Soprano", handle: "@singer"),
            Performer(id: UUID(), name: "No Handle", role: "Soprano",
                      voiceOrInstrument: "Soprano", handle: ""),
        ]
        event.ocrResult = ocr
        event.eventHandles = "@org, @venue"

        var pd = PostingDay(day: .wednesday)
        pd.photoPaths = [URL(fileURLWithPath: "/photos/w1.jpg")]
        pd.tagHandles = ["@someone"]
        pd.nameMentions = ["Someone Else"]
        pd.photoTags = [URL(fileURLWithPath: "/photos/w1.jpg").absoluteString:
                            ["@photoperson", "Photo Person Two"]]
        pd.selectedPerformerIDs = ocr.performers.map(\.id)
        event.days[DayName.wednesday.rawValue] = pd
        return event
    }

    // MARK: - what the revision manifest now carries

    func testTheRevisionManifestSendsTheDaysHandles() throws {
        let manifest = PythonBridge.buildCaptionRevisionManifest(
            event: event(), day: .wednesday, program: ["performers": []],
            existing: ["caption": "before"], feedback: "make it shorter")

        let handles = try XCTUnwrap(manifest["tag_handles"] as? [String])
        XCTAssertEqual(handles, ["@org", "@venue", "@singer", "@someone", "@photoperson"])
    }

    func testTheRevisionManifestSendsTheDaysPlainNameCredits() throws {
        let manifest = PythonBridge.buildCaptionRevisionManifest(
            event: event(), day: .wednesday, program: ["performers": []],
            existing: ["caption": "before"], feedback: "make it shorter")

        let names = try XCTUnwrap(manifest["name_mentions"] as? [String])
        // A selected performer with no handle is credited by name, and both
        // the day's own mention and the photo tag come along.
        XCTAssertEqual(names, ["No Handle", "Someone Else", "Photo Person Two"])
    }

    func testTheRevisionManifestSendsPhotoTagsKeyedByPath() throws {
        let manifest = PythonBridge.buildCaptionRevisionManifest(
            event: event(), day: .wednesday, program: ["performers": []],
            existing: ["caption": "before"], feedback: "make it shorter")

        let tags = try XCTUnwrap(manifest["photo_tags"] as? [String: [String]])
        // Re-keyed from the absoluteString the UI stores to the POSIX path
        // Python lines up against `photos`, exactly as the week manifest does.
        XCTAssertEqual(tags["/photos/w1.jpg"], ["@photoperson", "Photo Person Two"])
    }

    func testADayWithNothingTaggedSendsEmptyListsRatherThanNoKey() throws {
        // Always sent, so Python cannot mistake "nothing was tagged" for "this
        // app version does not send tags" and fall back to a different rule.
        var bare = event()
        bare.eventHandles = ""
        bare.days[DayName.wednesday.rawValue] = PostingDay(day: .wednesday)

        let manifest = PythonBridge.buildCaptionRevisionManifest(
            event: bare, day: .wednesday, program: ["performers": []],
            existing: ["caption": "before"], feedback: "shorter")

        XCTAssertEqual(manifest["tag_handles"] as? [String], [])
        XCTAssertEqual(manifest["name_mentions"] as? [String], [])
    }

    // MARK: - the week manifest reads the same derivation

    func testTheWeekManifestAndTheRevisionManifestAgreeOnADay() async throws {
        // Not a self-agreeing check (L70): the expectation above is written
        // out by hand from the fixture, and this asserts the OTHER caller
        // lands on that same list, so a change to either side is caught.
        let week = try await PythonBridge.shared.buildManifest(event: event())
        let days = try XCTUnwrap(week["days"] as? [String: Any])
        let wednesday = try XCTUnwrap(days["wednesday"] as? [String: Any])

        XCTAssertEqual(wednesday["tag_handles"] as? [String],
                       ["@org", "@venue", "@singer", "@someone", "@photoperson"])
    }
}
