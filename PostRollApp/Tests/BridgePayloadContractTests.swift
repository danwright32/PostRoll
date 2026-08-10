import XCTest

/// The Swift half of the bridge payload key contract (#262).
///
/// `tests/fixtures/bridge_payload_contract.json` names every key the Python
/// generators write and what happens to it here. The Python suite proves that
/// file matches what Python emits. This one proves every key it marks `swift`
/// is genuinely READ on this side, not merely declared.
///
/// The fixture is read from the repo rather than copied into the bundle: a
/// copied file is a second version free to drift from the one Python reads,
/// which is the whole thing being prevented (same reasoning as
/// CollageGeometryFixtureTests).
///
/// Two proof styles. A `model` payload is populated, encoded, and decoded back:
/// the encode proves the key is in CodingKeys, and the round trip proves
/// `init(from:)` reads it, so deleting a line from a decoder fails here. A
/// `reader` payload is fed a dictionary carrying every declared key and the
/// result is checked for each one, which also covers readers that keep values
/// generically without naming a key at all.
final class BridgePayloadContractTests: XCTestCase {

    // MARK: - The contract

    private struct Contract {
        let payloads: [String: Payload]
        struct Payload {
            let swiftKeys: Set<String>
            let allKeys: Set<String>
        }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .deletingLastPathComponent()   // repo root
    }

    private func loadContract() throws -> Contract {
        let url = Self.repoRoot().appendingPathComponent("tests/fixtures/bridge_payload_contract.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let dict = try XCTUnwrap(raw as? [String: Any], "the contract is not a JSON object")

        var payloads: [String: Contract.Payload] = [:]
        for (name, value) in dict where !name.hasPrefix("_") {
            let entry = try XCTUnwrap(value as? [String: Any], "\(name) is malformed")
            let keys = try XCTUnwrap(entry["keys"] as? [String: Any], "\(name) has no keys")
            let swiftKeys = keys.compactMap { key, disposition -> String? in
                (disposition as? String) == "swift" ? key : nil
            }
            payloads[name] = .init(swiftKeys: Set(swiftKeys), allKeys: Set(keys.keys))
        }
        return Contract(payloads: payloads)
    }

    /// Assert a payload's declared `swift` keys are exactly the ones proved.
    ///
    /// Exactly, not "at least": a proof that covers a key the contract calls
    /// python_only means the two files disagree about what this side reads, and
    /// whichever is wrong, nobody would find out from a passing test.
    private func assertCovers(_ payload: String, _ proved: Set<String>,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let contract = try loadContract()
        let declared = try XCTUnwrap(contract.payloads[payload],
                                     "the contract has no payload named \(payload)",
                                     file: file, line: line)
        let missing = declared.swiftKeys.subtracting(proved)
        XCTAssertTrue(missing.isEmpty,
                      "\(payload): the contract says Swift reads \(missing.sorted()), and this "
                      + "test could not show that it does. Either wire the key or mark it "
                      + "python_only with the reason.",
                      file: file, line: line)
        let extra = proved.subtracting(declared.swiftKeys)
        XCTAssertTrue(extra.isEmpty,
                      "\(payload): Swift reads \(extra.sorted()), which the contract does not "
                      + "list as read. The two sides disagree about what crosses the bridge.",
                      file: file, line: line)
    }

    /// The keys a Codable value writes out, which are exactly the keys its
    /// CodingKeys can decode.
    private func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(dict.keys)
    }

    // MARK: - Guards on the guard

    func testTheContractIsFoundAndIsNotEmpty() throws {
        let contract = try loadContract()
        XCTAssertFalse(contract.payloads.isEmpty,
                       "a missing or gutted contract makes every assertion below vacuous")
    }

    func testEveryPayloadInTheContractHasAProofHere() throws {
        // Without this, adding a payload to the fixture silently gets no Swift
        // coverage at all, and the contract looks enforced while a whole payload
        // goes unchecked.
        let contract = try loadContract()
        let proved = Set(Self.provenPayloads)
        let unproven = Set(contract.payloads.keys).subtracting(proved)
        XCTAssertTrue(unproven.isEmpty,
                      "no Swift proof for \(unproven.sorted()). Add one, or this side of the "
                      + "contract is not being checked for those payloads.")
    }

    /// Every payload with a proof below. Kept beside the tests so the check
    /// above cannot pass by listing something that is not really covered.
    private static let provenPayloads = [
        "week_result", "week_timing", "run_progress", "day_caption", "blog_output",
        "revised_caption", "revised_blog", "swapped_blog", "ocr_result", "flag_review",
        "media_result", "media_day", "friday_clip_plan", "friday_clip_selection",
        "cover_result", "swap_reel_audio", "meta_import", "learn_suggestion",
    ]

    // MARK: - Model payloads

    func testWeekResultReadsEveryDeclaredKey() throws {
        var week = WeekGenerationResult()
        for day in DayName.allCases { week[day] = DayCaption(caption: "c-\(day.rawValue)") }
        week.blog = BlogOutput(title: "t", body: "b")
        week.errors = ["sunday": "e"]
        week.warnings = ["monday": [SkippedPhoto(file: "a.jpg", reason: "unreadable")]]
        week.stoppedReason = "capped"
        week.complete = false
        week.unrecognisedFailures = ["odd"]

        let keys = try encodedKeys(week)
        try assertCovers("week_result", keys)

        // The round trip is what proves init(from:) reads them, rather than the
        // keys merely existing on the encoding side.
        let back = try JSONDecoder().decode(
            WeekGenerationResult.self, from: try JSONEncoder().encode(week))
        XCTAssertEqual(back, week)
    }

    func testDayCaptionReadsEveryDeclaredKey() throws {
        var cap = DayCaption(caption: "c")
        cap.hashtags = ["#a"]
        cap.altTexts = ["alt"]
        cap.sceneLabels = ["scene"]
        cap.generatedCaption = "c"

        // generated_caption is this side's own bookkeeping, never sent by
        // Python, so it is not part of the contract and is excluded here.
        try assertCovers("day_caption", try encodedKeys(cap).subtracting(["generated_caption"]))
        XCTAssertEqual(try JSONDecoder().decode(
            DayCaption.self, from: try JSONEncoder().encode(cap)), cap)
    }

    func testRevisedCaptionReadsEveryDeclaredKey() throws {
        var cap = DayCaption(caption: "c")
        cap.hashtags = ["#a"]; cap.altTexts = ["alt"]; cap.sceneLabels = ["s"]
        try assertCovers("revised_caption", try encodedKeys(cap).subtracting(["generated_caption"]))
    }

    func testBlogOutputReadsEveryDeclaredKey() throws {
        var blog = BlogOutput(title: "t", body: "b")
        blog.photoCount = 3
        blog.findings = [BlogFinding(code: "c", message: "m", detail: "d")]
        blog.generatedBody = "b"
        blog.findingsBody = "b"

        // generated_body and findings_body are stamped here, not sent by Python.
        let ours: Set<String> = ["generated_body", "findings_body"]
        try assertCovers("blog_output", try encodedKeys(blog).subtracting(ours))
        XCTAssertEqual(try JSONDecoder().decode(
            BlogOutput.self, from: try JSONEncoder().encode(blog)), blog)
    }

    func testRevisedBlogReadsEveryDeclaredKey() throws {
        var blog = BlogOutput(title: "t", body: "b")
        blog.photoCount = 1
        blog.findings = [BlogFinding(code: "c", message: "m", detail: "d")]
        try assertCovers("revised_blog",
                         try encodedKeys(blog).subtracting(["generated_body", "findings_body"]))
    }

    func testSwappedBlogReadsEveryDeclaredKey() throws {
        // swap_blog_photos sends no title, so `title` must not be claimed as
        // read for this payload even though the model has the field.
        var blog = BlogOutput(title: "", body: "b")
        blog.photoCount = 1
        blog.findings = []
        let sent = try encodedKeys(blog)
            .subtracting(["generated_body", "findings_body", "title"])
        try assertCovers("swapped_blog", sent)
    }

    func testOCRResultReadsEveryDeclaredKey() throws {
        var ocr = OCRResult()
        ocr.performers = [Performer(id: UUID(), name: "n", role: "r",
                                    voiceOrInstrument: "v", handle: "h")]
        ocr.pieces = []
        ocr.scenes = []
        ocr.organizationNotes = "o"
        ocr.programNotes = "p"
        ocr.venueNotes = "v"
        ocr.productionDetails = "d"
        ocr.other = "sponsor note"

        try assertCovers("ocr_result", try encodedKeys(ocr))
        XCTAssertEqual(try JSONDecoder().decode(
            OCRResult.self, from: try JSONEncoder().encode(ocr)).other, "sponsor note")
    }

    func testFridayClipPlanReadsEveryDeclaredKey() throws {
        let plan = FridayClipPlan(selections: [], rationale: "why")
        try assertCovers("friday_clip_plan", try encodedKeys(plan))
    }

    func testFridayClipSelectionReadsEveryDeclaredKey() throws {
        let json = """
        {"clip_path": "/a.mov", "trim_in": 1.0, "trim_out": 4.0, "transition": "cut",
         "crop_x": 0.1, "crop_y": 0.2, "crop_confidence": "high"}
        """
        let sel = try JSONDecoder().decode(FridayClipSelection.self, from: Data(json.utf8))
        try assertCovers("friday_clip_selection", try encodedKeys(sel))
        XCTAssertEqual(sel.cropConfidence, "high",
                       "the per-shot crop fields must survive the crossing or the "
                       + "crop feature never surfaces")
    }

    func testMetaImportResultReadsEveryDeclaredKey() throws {
        let result = MetaImportResult(posts: [], warnings: ["w"])
        try assertCovers("meta_import", try encodedKeys(result))
    }

    func testRunProgressReadsEveryDeclaredKey() throws {
        let step = GenerationStep(label: "Writing the Sunday caption",
                                  index: 2, total: 7, done: false, updatedAt: 1_700_000_000)
        try assertCovers("run_progress", try encodedKeys(step))
        XCTAssertEqual(try JSONDecoder().decode(
            GenerationStep.self, from: try JSONEncoder().encode(step)), step)
    }

    func testFlagReviewReadsEveryDeclaredKey() throws {
        let json = #"{"assistant_reply": "ok", "patch": [{"op": "set"}], "resolved": true}"#
        let parsed = try JSONDecoder().decode(
            PythonBridge.FlagReviewResponse.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.assistantReply, "ok")
        XCTAssertEqual(parsed.patch?.count, 1)
        XCTAssertTrue(parsed.resolved)
        try assertCovers("flag_review", ["assistant_reply", "patch", "resolved"])
    }

    // MARK: - Reader payloads

    func testMediaResultReadsEveryDeclaredKey() throws {
        var json: [String: Any] = ["errors": ["tuesday": "ffmpeg died"]]
        for day in PythonBridge.PreviewGenerationResult.dayOrder {
            json[day] = ["story": "/p/\(day)/story.png"]
        }

        let parsed = PythonBridge.parseMediaOutput(json, fileExists: { _ in true })

        var proved: Set<String> = []
        for day in PythonBridge.PreviewGenerationResult.dayOrder where parsed.paths[day] != nil {
            proved.insert(day)
        }
        if !parsed.errors.isEmpty { proved.insert("errors") }
        try assertCovers("media_result", proved)

        XCTAssertEqual(parsed.errors["tuesday"], "ffmpeg died",
                       "per-day failures are the difference between an export that "
                       + "is missing a day and one that says so")
    }

    func testMediaDayReadsEveryDeclaredKey() throws {
        let dayDict: [String: Any] = [
            "story": "/p/story.png",
            "collage": "/p/collage.png",
            "story_cover": "/p/story_cover.png",
            "reel": "/p/reel.mp4",
            "reel_preview": "/p/reel_preview.png",
            "before_after": "/p/before_after.png",
            "cover": "/p/cover.png",
            "friday_clip_plan": ["selections": [], "rationale": "why"],
            "cover_pick": ["source_path": "/p/src.jpg", "rationale": "sharpest"],
        ]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        var proved = Set(parsed.paths.keys)
        if parsed.fridayClipPlan != nil { proved.insert("friday_clip_plan") }
        if parsed.coverPick != nil { proved.insert("cover_pick") }
        try assertCovers("media_day", proved)
    }

    func testCoverResultReadsEveryDeclaredKey() throws {
        let parsed = PythonBridge.parseCoverRegenerationOutput([
            "cover": "/p/cover.png",
            "cover_pick": ["source_path": "/p/src.jpg", "rationale": "sharpest"],
        ])
        var proved: Set<String> = []
        if parsed?.coverPath != nil { proved.insert("cover") }
        if parsed?.coverPick != nil { proved.insert("cover_pick") }
        try assertCovers("cover_result", proved)
    }

    func testSwapReelAudioReadsEveryDeclaredKey() throws {
        let parsed = PythonBridge.parseSwapReelAudioOutput([
            "reel": "/p/reel.mp4", "audio_source": "/c/t.mp3", "tags": "strings",
        ])
        var proved: Set<String> = []
        if parsed?.reelPath != nil { proved.insert("reel") }
        if parsed?.audioSource != nil { proved.insert("audio_source") }
        if parsed?.tags != nil { proved.insert("tags") }
        try assertCovers("swap_reel_audio", proved)
    }

    func testLearnSuggestionReadsEveryDeclaredKey() throws {
        let parsed = PythonBridge.parseLearnSuggestion(["suggestion": "Write shorter openings."])
        XCTAssertEqual(parsed, "Write shorter openings.")
        try assertCovers("learn_suggestion", ["suggestion"])
    }

    func testWeekTimingReadsEveryDeclaredKey() throws {
        let parsed = PythonBridge.parseWeekTiming(["captions": 120.0, "blog": 60.0, "packaging": 5.0])
        var proved: Set<String> = []
        if parsed.captions != nil { proved.insert("captions") }
        if parsed.blog != nil { proved.insert("blog") }
        if parsed.packaging != nil { proved.insert("packaging") }
        try assertCovers("week_timing", proved)
    }

    func testAPhaseThatDidNotRunStaysNilRatherThanBecomingZero() {
        // A week with no blog photos reports blog: null. Scoring that as zero
        // seconds drags the estimate down with a measurement never taken.
        let parsed = PythonBridge.parseWeekTiming(["captions": 120.0, "blog": nil, "packaging": 5.0])
        XCTAssertNil(parsed.blog)
        XCTAssertEqual(parsed.captions, 120.0)
    }
}
