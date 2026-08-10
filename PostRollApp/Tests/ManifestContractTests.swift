import XCTest

/// The Swift half of the manifest contract (#266).
///
/// `tests/fixtures/bridge_payload_contract.json` declares, under `manifests`,
/// every key Python reads out of a manifest this side builds, and whether it is
/// always sent or sent conditionally. The Python suite proves that list matches
/// what Python really reads. This proves the app really sends the `always` ones.
///
/// This is the half that catches the defect. A key Swift stops sending does not
/// fail anywhere on its own: Python's `.get(key, default)` substitutes the
/// default and generation carries on producing something subtly different, so
/// the failure surfaces as a caption written from the wrong photos or a reel cut
/// to the wrong length, weeks later, with nothing pointing at the cause.
///
/// Every manifest below is built from an Event with EVERYTHING populated, so a
/// conditional key's absence can only mean the code stopped sending it, not that
/// the fixture forgot to set it up.
final class ManifestContractTests: XCTestCase {

    // MARK: - The contract

    private func manifestKeys(_ name: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("tests/fixtures/bridge_payload_contract.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let doc = try XCTUnwrap(raw as? [String: Any])
        let manifests = try XCTUnwrap(doc["manifests"] as? [String: Any],
                                      "the contract has no manifests section")
        let entry = try XCTUnwrap(manifests[name] as? [String: Any],
                                  "the contract has no manifest named \(name)")
        let keys = try XCTUnwrap(entry["keys"] as? [String: Any])
        return Set(keys.compactMap { key, disposition in
            (disposition as? String) == "always" ? key : nil
        })
    }

    /// Assert every always-sent key is present, and say which is missing.
    private func assertSends(_ manifest: [String: Any], _ contractName: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let required = try manifestKeys(contractName)
        XCTAssertFalse(required.isEmpty,
                       "\(contractName) declares no always-sent keys, so this proves nothing",
                       file: file, line: line)
        let missing = required.subtracting(manifest.keys)
        XCTAssertTrue(missing.isEmpty,
                      "\(contractName): the app does not send \(missing.sorted()). Python "
                      + "reads them and will quietly use its own defaults instead, which "
                      + "changes what gets generated rather than failing.",
                      file: file, line: line)
    }

    // MARK: - A fully populated event

    /// Everything set, so an absent key can only be the code's doing.
    private func fullEvent() -> Event {
        var event = Event(name: "Spring Concert", org: "Every Voice Choirs",
                          venue: "Carnegie Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var ocr = OCRResult()
        ocr.performers = [Performer(id: UUID(), name: "A Singer", role: "Soprano",
                                    voiceOrInstrument: "Soprano", handle: "@singer")]
        ocr.pieces = [Piece(composer: "A Composer", title: "A Work")]
        ocr.other = "Sponsored by the Hartwell Foundation."
        event.ocrResult = ocr
        event.eventHandles = "@org, @venue"
        event.venueContext = "A hall."
        event.eventURL = "https://example.org/spring"
        event.blogPhotoPaths = [URL(fileURLWithPath: "/photos/blog1.jpg")]

        for day in DayName.allCases {
            var pd = PostingDay(day: day)
            pd.photoPaths = [URL(fileURLWithPath: "/photos/\(day.rawValue)_1.jpg"),
                             URL(fileURLWithPath: "/photos/\(day.rawValue)_2.jpg")]
            pd.tagHandles = ["@someone"]
            pd.nameMentions = ["Someone Else"]
            pd.notes = "What happened in the room."
            pd.photoTags = [URL(fileURLWithPath: "/photos/\(day.rawValue)_1.jpg").absoluteString: ["A Singer"]]
            pd.selectedPerformerIDs = ocr.performers.map(\.id)
            pd.rawPhotoPath = URL(fileURLWithPath: "/photos/raw.jpg")
            pd.editedPhotoPath = URL(fileURLWithPath: "/photos/edit.jpg")
            pd.bwPhotoPath = URL(fileURLWithPath: "/photos/bw.jpg")
            pd.screenRecordingPath = URL(fileURLWithPath: "/photos/screen.mov")
            pd.audioPath = URL(fileURLWithPath: "/audio/track.mp3")
            pd.clipPaths = [URL(fileURLWithPath: "/clips/a.mov")]
            pd.collageSeed = 42
            pd.reelSeed = 7
            pd.scrollDuration = 40
            pd.reelTargetDuration = 20
            pd.cropOffsets = [URL(fileURLWithPath: "/photos/\(day.rawValue)_1.jpg").absoluteString:
                                CropOffset(x: 0, y: -1, scale: 1)]
            pd.fridayClipPlan = FridayClipPlan(selections: [], rationale: "why")
            event.days[day.rawValue] = pd
        }
        return event
    }

    // MARK: - Week generation

    func testTheWeekManifestSendsEveryRequiredKey() async throws {
        let manifest = try await PythonBridge.shared.buildManifest(event: fullEvent())
        try assertSends(manifest, "week")
    }

    func testEachDayInTheWeekManifestSendsEveryRequiredKey() async throws {
        let manifest = try await PythonBridge.shared.buildManifest(event: fullEvent())
        let days = try XCTUnwrap(manifest["days"] as? [String: Any])
        XCTAssertFalse(days.isEmpty, "no days at all would pass the loop below vacuously")
        for (name, entry) in days {
            try assertSends(try XCTUnwrap(entry as? [String: Any]), "week_day")
            XCTAssertNotNil(DayName(rawValue: name), "unexpected day key \(name)")
        }
    }

    // MARK: - Media generation

    func testTheMediaManifestSendsEveryRequiredKey() async {
        let manifest = await PythonBridge.shared.buildMediaManifest(event: fullEvent())
        XCTAssertNoThrow(try assertSends(manifest, "media"))
    }

    func testEachDayInTheMediaManifestSendsEveryRequiredKey() async throws {
        let manifest = await PythonBridge.shared.buildMediaManifest(event: fullEvent())
        let days = try XCTUnwrap(manifest["days"] as? [String: Any])
        XCTAssertFalse(days.isEmpty)
        for (_, entry) in days {
            try assertSends(try XCTUnwrap(entry as? [String: Any]), "media_day")
        }
    }

    // MARK: - Cover regeneration

    func testTheCoverManifestSendsEveryRequiredKey() throws {
        var event = fullEvent()
        // buildCoverManifest only refreshes an ALREADY rendered cover, so the
        // day has to have one for the manifest to exist at all.
        event.previewMediaPaths["thursday"] = ["cover": "/previews/thursday/cover.png"]

        let manifest = try XCTUnwrap(
            PythonBridge.buildCoverManifest(event: event, day: .thursday, overrideSource: nil),
            "no cover manifest was built for a day that has a rendered cover")

        var flattened = manifest
        // `photos` is read off the nested day_info, and the contract lists the
        // two together because Python reads them from one manifest.
        if let dayInfo = manifest["day_info"] as? [String: Any] {
            flattened.merge(dayInfo) { current, _ in current }
        }
        try assertSends(flattened, "cover")
    }

    // MARK: - Friday override

    func testTheFridayOverrideManifestSendsEveryRequiredKey() throws {
        let event = fullEvent()
        let overrides = [ReelClipOverride(clipPath: "/clips/a.mov", order: 0,
                                          included: true, trimIn: 0, trimOut: 3,
                                          cropX: 0, cropY: 0)]
        let manifest = PythonBridge.buildFridayOverrideManifest(event: event, override: overrides)
        try assertSends(manifest, "friday_override")
    }

    func testAFridayReRenderKeepsTheTrackDanUploaded() {
        // Python reads `audio` to reuse an uploaded track and fetches a fresh
        // one when it is absent, so a missing key is not a missing setting: it
        // is a different instruction, and the music silently changes under him.
        var event = fullEvent()
        var fri = event.days[DayName.friday.rawValue]!
        fri.audioPath = URL(fileURLWithPath: "/audio/dans_own_track.wav")
        event.days[DayName.friday.rawValue] = fri

        let manifest = PythonBridge.buildFridayOverrideManifest(
            event: event,
            override: [ReelClipOverride(clipPath: "/clips/a.mov", order: 0,
                                        included: true, trimIn: 0, trimOut: 3,
                                        cropX: 0, cropY: 0)])

        XCTAssertEqual(manifest["audio"] as? String, "/audio/dans_own_track.wav")
    }

    func testAFridayWithNoUploadedTrackSendsNoAudioKeyAtAll() {
        // An empty string is a different request from an absent key: it would
        // ask Python to use a file at path "".
        var event = fullEvent()
        var fri = event.days[DayName.friday.rawValue]!
        fri.audioPath = nil
        event.days[DayName.friday.rawValue] = fri

        let manifest = PythonBridge.buildFridayOverrideManifest(
            event: event,
            override: [ReelClipOverride(clipPath: "/clips/a.mov", order: 0,
                                        included: true, trimIn: 0, trimOut: 3,
                                        cropX: 0, cropY: 0)])

        XCTAssertNil(manifest["audio"])
    }

    // MARK: - The eight smaller manifests (#270)

    func testTheReelPreviewManifestSendsEveryRequiredKey() throws {
        let pd = try XCTUnwrap(fullEvent().days[DayName.thursday.rawValue])
        let manifest = PythonBridge.buildReelPreviewManifest(
            day: pd, cropOffsets: [[0, -1, 1.0]])
        try assertSends(manifest, "reel_preview")
    }

    func testAnUntouchedDaySendsNoCropOffsets() throws {
        // All-default offsets are not crops. Sending them would ask Python to
        // apply a pan of zero to every photo, which is not the same request as
        // "this day was never adjusted".
        let pd = try XCTUnwrap(fullEvent().days[DayName.thursday.rawValue])
        let manifest = PythonBridge.buildReelPreviewManifest(
            day: pd, cropOffsets: [[0, 0, 1.0], [0, 0, 1.0]])
        XCTAssertNil(manifest["crop_offsets"])
    }

    func testTheAudioSwapManifestSendsEveryRequiredKey() throws {
        try assertSends(PythonBridge.buildSwapReelAudioManifest(event: fullEvent()),
                        "swap_reel_audio")
    }

    func testTheAudioSwapStillSendsPiecesWhenTheProgrammeHasNone() throws {
        // `pieces` is what the music is matched on. An event with no programme
        // still has to send the key, or the match silently changes shape.
        var event = fullEvent()
        event.ocrResult?.pieces = []
        let manifest = PythonBridge.buildSwapReelAudioManifest(event: event)
        try assertSends(manifest, "swap_reel_audio")
        XCTAssertEqual((manifest["pieces"] as? [[String: String]])?.count, 0)
    }

    func testTheCaptionRevisionManifestSendsEveryRequiredKey() throws {
        try assertSends(
            PythonBridge.buildCaptionRevisionManifest(
                event: fullEvent(), day: .wednesday, program: ["performers": []],
                existing: ["caption": "before"], feedback: "make it shorter"),
            "caption_revision")
    }

    func testTheBlogRevisionManifestSendsEveryRequiredKey() throws {
        try assertSends(
            PythonBridge.buildBlogRevisionManifest(
                event: fullEvent(), program: ["performers": []],
                existing: ["body": "before"], feedback: "make it shorter"),
            "blog_revision")
    }

    func testTheBlogPhotoSwapManifestSendsEveryRequiredKey() throws {
        try assertSends(
            PythonBridge.buildBlogPhotoSwapManifest(
                currentBody: "a post", photoPaths: [URL(fileURLWithPath: "/p/a.jpg")],
                event: fullEvent()),
            "blog_photo_swap")
    }

    func testABlogPhotoSwapWithNoEventStillSendsWhatItHas() {
        // One caller has no event. Python defaults the venue and copes without
        // the programme, so this is a real conditional rather than a lost key.
        let manifest = PythonBridge.buildBlogPhotoSwapManifest(
            currentBody: "a post", photoPaths: [URL(fileURLWithPath: "/p/a.jpg")], event: nil)
        XCTAssertNotNil(manifest["body"])
        XCTAssertNotNil(manifest["photo_paths"])
        XCTAssertNil(manifest["venue"])
        XCTAssertNil(manifest["program"])
    }

    func testAnEventWithNoProgrammeStillSwapsBlogPhotos() {
        // The programme is the optional half; the venue is not.
        var event = fullEvent()
        event.ocrResult = nil
        let manifest = PythonBridge.buildBlogPhotoSwapManifest(
            currentBody: "a post", photoPaths: [URL(fileURLWithPath: "/p/a.jpg")], event: event)
        XCTAssertEqual(manifest["venue"] as? String, "Carnegie Hall")
        XCTAssertNil(manifest["program"])
    }

    func testTheAnalyticsManifestSendsEveryRequiredKey() throws {
        try assertSends(
            PythonBridge.buildAnalyticsManifest(
                posts: [["id": "1"]], orgBands: ["Org": "small"], globalHashtags: ["#nyc"]),
            "analytics")
    }

    func testTheLearnFromEditsManifestSendsEveryRequiredKey() throws {
        try assertSends(
            PythonBridge.buildLearnFromEditsManifest(
                brandVoice: "the voice", edits: [["day": "sunday"]]),
            "learn_suggestion")
    }

    func testTheBrandVoiceIsSentEvenWhenEmpty() throws {
        // Python loads the file itself when the key is absent. Two copies of
        // the voice that can disagree is worse than one that is briefly blank,
        // so the key goes either way.
        let manifest = PythonBridge.buildLearnFromEditsManifest(brandVoice: "", edits: [])
        try assertSends(manifest, "learn_suggestion")
        XCTAssertEqual(manifest["brand_voice"] as? String, "")
    }

    // MARK: - The guard on the guard

    /// Every manifest with a proof above. Without this check, adding a manifest
    /// to the contract silently gets no Swift coverage at all, and the file
    /// looks enforced while a whole manifest goes unchecked.
    private static let provenManifests = [
        "week", "week_day", "media", "media_day", "cover", "friday_override",
        "reel_preview", "swap_reel_audio", "caption_revision", "blog_revision",
        "blog_photo_swap", "analytics", "learn_suggestion",
    ]

    func testEveryManifestInTheContractHasAProofHere() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("tests/fixtures/bridge_payload_contract.json")
        let doc = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let manifests = try XCTUnwrap(doc["manifests"] as? [String: Any])
        let declared = Set(manifests.keys.filter { !$0.hasPrefix("_") })
        XCTAssertFalse(declared.isEmpty)

        let unproven = declared.subtracting(Self.provenManifests)
        XCTAssertTrue(unproven.isEmpty,
                      "no Swift proof for \(unproven.sorted()). Add one, or the app is free to "
                      + "stop sending those keys and nothing here would notice.")
    }


    func testAMissingRequiredKeyIsReported() throws {
        // Proves the assertion can fail. A contract check that only ever passes
        // is indistinguishable from no check, and this one is otherwise only
        // exercised by manifests that already satisfy it.
        let required = try manifestKeys("week")
        XCTAssertTrue(required.contains("event"))
        let crippled: [String: Any] = ["days": [:]]
        XCTAssertFalse(required.subtracting(crippled.keys).isEmpty,
                       "a manifest missing almost everything must not read as complete")
    }
}
