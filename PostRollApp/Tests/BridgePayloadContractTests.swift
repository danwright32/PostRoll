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
        let raw = try JSONSerialization.jsonObject(
            with: try RepoFixture.data("tests/fixtures/bridge_payload_contract.json"))
        let dict = try XCTUnwrap(raw as? [String: Any], "the contract is not a JSON object")

        // `manifests` is a section of the file, not a payload. Named rather
        // than inferred, so adding a section cannot silently become a payload
        // that every consumer then fails to parse.
        let reserved: Set<String> = ["manifests"]

        var payloads: [String: Contract.Payload] = [:]
        for (name, value) in dict where !name.hasPrefix("_") && !reserved.contains(name) {
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
        "caption_finding",
        "week_result", "week_timing", "run_progress", "day_caption", "blog_output",
        "revised_caption", "revised_blog", "swapped_blog", "ocr_result", "flag_review",
        "media_result", "media_day", "friday_clip_plan", "friday_clip_selection",
        "cover_result", "swap_reel_audio", "friday_override_result",
        "meta_import", "learn_suggestion",
        "web_performers", "handle_suggestions", "piece_notes", "ocr_flags",
        "collage_candidates", "insight_report",
        // The shapes one level DOWN (#274). The contract used to confirm that
        // `performers`, `pieces` and `scenes` arrived and check nothing inside
        // them, so a field renamed a level down went missing exactly the way
        // OCR's `other` did for years: the outer key still arrives, so nothing
        // looks broken.
        "ocr_performer", "program_piece", "program_scene", "ig_post",
        "insight_findings", "insight_finding", "blog_finding",
        "account_numbers",
        "retried_blog_repair",
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
        blog.findings = [QualityFinding(code: "c", message: "m", detail: "d")]
        blog.generatedBody = "b"
        blog.findingsBody = "b"

        // `generated_body` is stamped on this side: it answers "has Dan edited
        // this", which only the app can know. `findings_body` used to be listed
        // beside it and was not the same thing at all: it answers "do these
        // findings still describe what is on screen", which only the half that
        // ran the checks knows. Nothing emitted it, so it decoded empty on
        // every generated post and the panel could never go stale (#974).
        let ours: Set<String> = ["generated_body"]
        try assertCovers("blog_output", try encodedKeys(blog).subtracting(ours))
        XCTAssertEqual(try JSONDecoder().decode(
            BlogOutput.self, from: try JSONEncoder().encode(blog)), blog)
    }

    func testRevisedBlogReadsEveryDeclaredKey() throws {
        var blog = BlogOutput(title: "t", body: "b")
        blog.photoCount = 1
        blog.findings = [QualityFinding(code: "c", message: "m", detail: "d")]
        blog.findingsBody = "b"
        try assertCovers("revised_blog",
                         try encodedKeys(blog).subtracting(["generated_body"]))
    }

    func testSwappedBlogReadsEveryDeclaredKey() throws {
        // swap_blog_photos sends no title, so `title` must not be claimed as
        // read for this payload even though the model has the field.
        var blog = BlogOutput(title: "", body: "b")
        blog.photoCount = 1
        blog.findings = []
        blog.findingsBody = "b"
        let sent = try encodedKeys(blog)
            .subtracting(["generated_body", "title"])
        try assertCovers("swapped_blog", sent)
    }

    func testRetriedBlogRepairReadsEveryDeclaredKey() throws {
        // #1160. The retry sends the body it ended with, the findings measured
        // on exactly that body, and what it actually did. The last part is not
        // decoration: repairs are silent, so a retry that repaired nothing and
        // one that never ran would otherwise read identically here.
        var result = BlogRepairRetryResult()
        result.body = "b"
        result.findings = [QualityFinding(code: "c", message: "m", detail: "d",
                                          repair: "blocked", target: "a.jpg")]
        result.retry = .init(ran: true, selected: 1, repaired: 1)

        try assertCovers("retried_blog_repair", try encodedKeys(result))
        XCTAssertEqual(try JSONDecoder().decode(
            BlogRepairRetryResult.self,
            from: try JSONEncoder().encode(result)), result)
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

    // MARK: - The results the first sweep missed (#273)

    func testWebPerformersReadEveryDeclaredKey() throws {
        // Who was on stage. A different shape from a handle suggestion, and
        // decoded into a different model: swapping the two would drop every
        // field silently, since both decoders tolerate anything missing.
        let json = #"[{"name": "A Singer", "role": "soloist", "voice_or_instrument": "Soprano"}]"#
        let people = try JSONDecoder().decode([Performer].self, from: Data(json.utf8))
        let p = try XCTUnwrap(people.first)
        XCTAssertEqual(p.name, "A Singer")
        XCTAssertEqual(p.role, "soloist")
        XCTAssertEqual(p.voiceOrInstrument, "Soprano")
        try assertCovers("web_performers", ["name", "role", "voice_or_instrument"])
    }

    func testAFetchedPerformerGetsAnIdentityAndAnEmptyHandle() throws {
        // Python sends neither: the identity is this side's, and the handle is
        // what the separate suggestion lookup is for.
        let json = #"[{"name": "A Singer", "role": "ensemble"}]"#
        let people = try JSONDecoder().decode([Performer].self, from: Data(json.utf8))
        XCTAssertEqual(people.first?.handle, "")
        XCTAssertNotNil(people.first?.id)
    }

    func testHandleSuggestionsReadEveryDeclaredKey() throws {
        let json = """
        [{"name": "A Singer", "handle": "@singer",
          "profile_url": "https://instagram.com/singer",
          "confidence": "medium", "note": "bio matches"}]
        """
        let out = try JSONDecoder().decode(
            [PythonBridge.HandleSuggestion].self, from: Data(json.utf8))
        let s = try XCTUnwrap(out.first)
        XCTAssertEqual(s.name, "A Singer")
        XCTAssertEqual(s.handle, "@singer")
        XCTAssertEqual(s.confidence, "medium")
        try assertCovers("handle_suggestions",
                         ["name", "handle", "profile_url", "confidence", "note"])
    }

    func testAccountNumbersReadEveryDeclaredKey() throws {
        // Every key, including the nulls, because `AccountStats.merged` treats
        // an absent field and a null one differently: one replaces what is
        // stored and the other leaves it alone (#1003). A row that dropped its
        // nulls would silently stop clearing a figure the fetch no longer has.
        let json = """
        {"accounts": [{"handle": "someone", "outcome": "measured",
          "followers": 1000, "likes": 50, "comments": 5,
          "likes_hidden": false, "followers_from_page": false,
          "instagram_id": "17841400000000000", "reels": 2, "feed": 4,
          "detail": "Read from 12 recent posts.", "allowance_spent": 3}]}
        """
        struct Answer: Codable { let accounts: [PythonBridge.AccountFigures] }
        let out = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        let row = try XCTUnwrap(out.accounts.first)

        XCTAssertEqual(row.handle, "someone")
        XCTAssertEqual(row.outcome, "measured")
        XCTAssertEqual(row.followers, 1_000)
        XCTAssertEqual(row.instagramID, "17841400000000000")
        XCTAssertEqual(row.reels, 2)
        XCTAssertEqual(row.feed, 4)
        XCTAssertFalse(row.likesHidden)
        XCTAssertFalse(row.followersFromPage)
        XCTAssertEqual(row.allowanceSpent, 3)

        // And the whole point of carrying it: what lands in the book.
        let stats = row.stats(recordedOn: Date(timeIntervalSince1970: 1_775_000_000))
        XCTAssertEqual(stats.outcome, .measured)
        XCTAssertEqual(stats.likesSource, .measured)

        try assertCovers("account_numbers",
                         ["handle", "outcome", "followers", "likes", "comments",
                          "likes_hidden", "followers_from_page", "instagram_id",
                          "reels", "feed", "detail", "allowance_spent"])
    }

    func testAWithheldLikeCountCrossesAsHiddenRatherThanAbsent() throws {
        // The one field where null and refused are different things, so the
        // boolean has to travel BESIDE the null rather than instead of it, and
        // it has to still be hidden on the Swift side of the trip (#1032).
        let json = """
        {"accounts": [{"handle": "someone", "outcome": "measured",
          "followers": 5244, "likes": null, "comments": 8,
          "likes_hidden": true, "followers_from_page": false,
          "instagram_id": null, "reels": null, "feed": null, "detail": "",
          "allowance_spent": null}]}
        """
        struct Answer: Codable { let accounts: [PythonBridge.AccountFigures] }
        let out = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        let stats = try XCTUnwrap(out.accounts.first)
            .stats(recordedOn: Date(timeIntervalSince1970: 1_775_000_000))

        XCTAssertNil(stats.likes)
        XCTAssertEqual(stats.likesSource, .hidden)
        XCTAssertTrue(stats.likesAreHidden)
    }

    func testAnOutcomeThisBuildDoesNotKnowCrossesAsUnclassified() throws {
        // The Python side may learn an eighth outcome. The honest reading of a
        // word we do not know is that the account was not classified, which is
        // retryable and claims nothing, rather than throwing and losing the
        // whole answer (L337).
        let json = """
        {"accounts": [{"handle": "someone", "outcome": "invented_later",
          "followers": null, "likes": null, "comments": null,
          "likes_hidden": false, "followers_from_page": false,
          "instagram_id": null, "reels": null, "feed": null, "detail": "",
          "allowance_spent": null}]}
        """
        struct Answer: Codable { let accounts: [PythonBridge.AccountFigures] }
        let out = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        let stats = try XCTUnwrap(out.accounts.first)
            .stats(recordedOn: Date(timeIntervalSince1970: 1_775_000_000))

        XCTAssertEqual(stats.outcome, .couldNotClassify)
    }

    func testPieceNotesReadEveryDeclaredKey() throws {
        let json = #"[{"title": "A Work", "composer": "A Composer", "notes": "written in 1899"}]"#
        let out = try JSONDecoder().decode(
            [PythonBridge.PieceNoteResult].self, from: Data(json.utf8))
        let n = try XCTUnwrap(out.first)
        XCTAssertEqual(n.title, "A Work")
        XCTAssertEqual(n.composer, "A Composer")
        XCTAssertEqual(n.notes, "written in 1899")
        try assertCovers("piece_notes", ["title", "composer", "notes"])
    }

    func testAPieceWithNoNoteFoundStillDecodes() throws {
        // Kept rather than dropped, because it records that the lookup happened
        // and is what stops the same piece being paid for again.
        let json = #"[{"title": "A Work", "composer": "A Composer", "notes": null}]"#
        let out = try JSONDecoder().decode(
            [PythonBridge.PieceNoteResult].self, from: Data(json.utf8))
        XCTAssertEqual(out.first?.title, "A Work")
        XCTAssertNil(out.first?.notes)
    }

    func testOCRFlagsReadEveryDeclaredKey() throws {
        var flag = OCRFlag(id: "flag_0", fieldPath: [], currentValue: "Smth",
                           concern: "looks misread")
        flag.suggestedValue = "Smith"
        flag.programContext = "cast list, page 2"

        // `resolved` is this side's own bookkeeping (whether Dan has dealt with
        // the flag), never sent by Python, so it is excluded from the contract.
        try assertCovers("ocr_flags", try encodedKeys(flag).subtracting(["resolved"]))
        XCTAssertEqual(try JSONDecoder().decode(
            OCRFlag.self, from: try JSONEncoder().encode(flag)), flag)
    }

    func testCollageCandidatesReadEveryDeclaredKey() throws {
        let candidate = CollageCandidate(seed: 42, path: "/previews/cand_42.png")
        try assertCovers("collage_candidates", try encodedKeys(candidate))
        XCTAssertEqual(try JSONDecoder().decode(
            CollageCandidate.self, from: try JSONEncoder().encode(candidate)), candidate)
    }

    func testTheInsightReportReadsEveryDeclaredKey() throws {
        let findings = InsightFindings(captionPatterns: [], hashtagPatterns: [],
                                       contentTypePatterns: [], timingPatterns: [])
        let report = InsightReport(
            id: UUID(), generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dateRangeStart: Date(timeIntervalSince1970: 1_600_000_000),
            dateRangeEnd: Date(timeIntervalSince1970: 1_700_000_000),
            postCount: 10, storyCount: 4, feedCount: 6, summary: "what worked",
            feedFindings: findings, storyFindings: findings,
            brandVoiceSuggestions: ["shorter openings"], caveats: ["small sample"],
            analyzedCount: 10, uncontrolledCount: 3, uncreditedCount: 1,
            uncontrolledOrgs: ["newchoir"])

        // `id` is stamped by Python's own uuid pass rather than named in the
        // report shell, so it is not part of the declared key set.
        try assertCovers("insight_report", try encodedKeys(report).subtracting(["id"]))
        XCTAssertEqual(try JSONDecoder().decode(
            InsightReport.self, from: try JSONEncoder().encode(report)), report)
    }

    // MARK: - Nested shapes (#274)

    func testAnOCRPerformerReadsEveryDeclaredKey() throws {
        let json = #"{"name": "A Singer", "role": "soloist", "voice_or_instrument": "Soprano"}"#
        let p = try JSONDecoder().decode(Performer.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "A Singer")
        XCTAssertEqual(p.role, "soloist")
        XCTAssertEqual(p.voiceOrInstrument, "Soprano")
        try assertCovers("ocr_performer", ["name", "role", "voice_or_instrument"])
    }

    func testAProgramPieceReadsEveryDeclaredKey() throws {
        let json = #"""
        {"composer": "Bach", "title": "St Matthew Passion",
         "movements": ["Part I", "Part II"], "notes": "premiered 1727"}
        """#
        let piece = try JSONDecoder().decode(Piece.self, from: Data(json.utf8))
        XCTAssertEqual(piece.composer, "Bach")
        XCTAssertEqual(piece.title, "St Matthew Passion")
        XCTAssertEqual(piece.movements, ["Part I", "Part II"])
        XCTAssertEqual(piece.notes, "premiered 1727")
        try assertCovers("program_piece", ["composer", "title", "movements", "notes"])
    }

    func testAProgramSceneReadsEveryDeclaredKey() throws {
        // visual_cues is the one that matters most and the one a rename would
        // hide: it is what the caption pipeline matches photos against.
        let json = #"""
        {"name": "spa scene", "location": "New Mexico",
         "visual_cues": "two actors at a small table", "description": "what happens"}
        """#
        let scene = try JSONDecoder().decode(ProgramScene.self, from: Data(json.utf8))
        XCTAssertEqual(scene.name, "spa scene")
        XCTAssertEqual(scene.location, "New Mexico")
        XCTAssertEqual(scene.visualCues, "two actors at a small table")
        XCTAssertEqual(scene.description, "what happens")
        try assertCovers("program_scene",
                         ["name", "location", "visual_cues", "description"])
    }

    func testAnIGPostReadsEveryDeclaredKey() throws {
        let post = IGPost(
            igPostID: "1", igPermalink: "https://example.com/p/1",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mediaType: .reel, caption: "a caption",
            hashtags: ["#one"], views: 1, reach: 2, likes: 3, shares: 4, follows: 5,
            comments: 6, saves: 7, replies: 8, navigation: 9, profileVisits: 10,
            stickerTaps: 11, durationSec: 12.5, org: "@dciny", isPersonal: false)

        let keys = try encodedKeys(post)
        try assertCovers("ig_post", keys)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(IGPost.self, from: try encoder.encode(post))
        XCTAssertEqual(back, post)
    }

    func testAFindingsTrackReadsEveryDeclaredKey() throws {
        let one = InsightFinding(id: UUID(), headline: "h", evidence: "e", confidence: .high)
        let findings = InsightFindings(captionPatterns: [one], hashtagPatterns: [one],
                                       contentTypePatterns: [one], timingPatterns: [one])

        let keys = try encodedKeys(findings)
        try assertCovers("insight_findings", keys)

        let back = try JSONDecoder().decode(
            InsightFindings.self, from: try JSONEncoder().encode(findings))
        XCTAssertEqual(back, findings)
    }

    func testAnInsightFindingReadsEveryDeclaredKey() throws {
        // `id` is stamped by Python's _assign_ids after the entry is shaped, so
        // it is not part of the declared shape and is subtracted here.
        let finding = InsightFinding(id: UUID(), headline: "h", evidence: "e",
                                     confidence: .medium)
        try assertCovers("insight_finding", try encodedKeys(finding).subtracting(["id"]))

        let json = #"{"headline": "h", "evidence": "e", "confidence": "medium"}"#
        let back = try JSONDecoder().decode(InsightFinding.self, from: Data(json.utf8))
        XCTAssertEqual(back.headline, "h")
        XCTAssertEqual(back.evidence, "e")
        XCTAssertEqual(back.confidence, .medium)
    }

    func testABlogFindingReadsEveryDeclaredKey() throws {
        let finding = QualityFinding(code: "c", message: "m", detail: "d")
        try assertCovers("blog_finding", try encodedKeys(finding))

        let back = try JSONDecoder().decode(
            QualityFinding.self, from: try JSONEncoder().encode(finding))
        XCTAssertEqual(back, finding)
    }

    func testACaptionFindingReadsEveryDeclaredKey() throws {
        // #1156. Caption findings are built by the same `finding_entry` as blog
        // findings and had no entry of their own, so #1132's `repair` field
        // reached them at runtime with nothing verifying the shape either side.
        // Nothing was broken; this is the drift the contract exists to catch
        // before it is.
        let finding = QualityFinding(code: "caption_credit_missing",
                                     message: "m", detail: "d")
        try assertCovers("caption_finding", try encodedKeys(finding))

        let back = try JSONDecoder().decode(
            QualityFinding.self, from: try JSONEncoder().encode(finding))
        XCTAssertEqual(back, finding)
    }

    func testACaptionFindingCarriesWhatTheRepairPassDid() throws {
        // The field that arrived without a contract. Read back rather than
        // merely declared: a key the app drops on decode is a key the panel
        // silently reports as never attempted (L46).
        let json = Data(#"""
        {"code": "c", "message": "m", "detail": "d", "repair": "blocked"}
        """#.utf8)

        let finding = try JSONDecoder().decode(QualityFinding.self, from: json)

        XCTAssertEqual(finding.repairState, .blocked)
    }

    // MARK: - Reader payloads

    func testMediaResultReadsEveryDeclaredKey() throws {
        var json: [String: Any] = [
            "errors": ["tuesday": "ffmpeg died"],
            "warnings": ["friday": "B&W photo not found: /photos/bw.jpg"],
        ]
        for day in PythonBridge.PreviewGenerationResult.dayOrder {
            json[day] = ["story": "/p/\(day)/story.png"]
        }

        let parsed = PythonBridge.parseMediaOutput(json, fileExists: { _ in true })

        var proved: Set<String> = []
        for day in PythonBridge.PreviewGenerationResult.dayOrder where parsed.paths[day] != nil {
            proved.insert(day)
        }
        if !parsed.errors.isEmpty { proved.insert("errors") }
        if !parsed.warnings.isEmpty { proved.insert("warnings") }
        try assertCovers("media_result", proved)

        XCTAssertEqual(parsed.errors["tuesday"], "ffmpeg died",
                       "per-day failures are the difference between an export that "
                       + "is missing a day and one that says so")
        XCTAssertEqual(parsed.warnings["friday"], "B&W photo not found: /photos/bw.jpg",
                       "a day that rendered with an optional input missing is a "
                       + "different fact from a day that produced nothing (#265)")
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

    func testFridayOverrideResultReadsEveryDeclaredKey() throws {
        let parsed = PythonBridge.parseFridayOverrideOutput([
            "reel": "/p/reel.mp4",
            "title_card_skipped": "title card skipped, so the reel carries no title: ffmpeg failed",
        ])
        var proved: Set<String> = []
        if parsed?.reelPath != nil { proved.insert("reel") }
        if parsed?.titleCardSkipped != nil { proved.insert("title_card_skipped") }
        try assertCovers("friday_override_result", proved)
    }

    /// The other two shapes this parser has to tell apart (#824).
    ///
    /// An empty reason means the reel HAS its title, and must not read as a
    /// reel that lost one: a caller checking only for a value would put a
    /// notice on every successful render, and a notice that fires on the normal
    /// case stops being read. A missing reel path is refused outright rather
    /// than guessed at, because that path is what the player reloads.
    func testFridayOverrideResultTellsATitledReelFromAnUntitledOne() throws {
        let titled = PythonBridge.parseFridayOverrideOutput([
            "reel": "/p/reel.mp4", "title_card_skipped": "",
        ])
        XCTAssertEqual(titled?.reelPath, "/p/reel.mp4")
        XCTAssertNil(titled?.titleCardSkipped,
                     "an empty reason means the title is on the reel, not that a title was lost")

        XCTAssertNil(PythonBridge.parseFridayOverrideOutput(["title_card_skipped": ""]),
                     "a result with no reel path says nothing the player can reload")
        XCTAssertNil(PythonBridge.parseFridayOverrideOutput(["reel": ""]),
                     "an empty reel path is not a path")
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
