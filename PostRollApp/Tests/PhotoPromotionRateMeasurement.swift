import XCTest

/// #1278: how often does the photo promotion suggestion actually fire?
///
/// `CollaboratorPick.photoToPromote` (#983) fires whenever ANY later photo
/// carries a stronger account than the first. The broad trigger was chosen
/// deliberately: a "much stronger" threshold would be a second constant
/// calibrated against a population nobody had measured, and whether a reorder is
/// worth it is Dan's call. The cost of that choice is noise, and since #964 the
/// collaborator panel renders on every posting day, so this is reachable on
/// every collage carousel day. A suggestion that appears on most posts stops
/// being read, and it sits directly above the findings that do need judgement
/// (L36).
///
/// ## Why this is a measurement rather than a test
///
/// It reads the LIVE store, which no test may do (L2), so it does nothing at
/// all unless `POSTROLL_MEASURE_PROMOTION` names a directory holding a COPY of
/// `events.json` and `accounts.json`. Without it every check here skips, which
/// is the honest state for a measurement nobody asked for.
///
/// It runs the shipping predicate rather than a reimplementation of it. A
/// number produced by a rule written beside the code is a second definition
/// that drifts, and in the direction that flatters whatever argument it is
/// being used for (L107).
///
/// ## What it prints
///
/// Counts only. No handles, no event names. A tool that reads a live system
/// delivers real names into transcripts and scrollback by a route no repository
/// scanner can see (L222), and an issue written with real evidence is what
/// whoever implements it copies into fixtures (L155).
///
///     POSTROLL_MEASURE_PROMOTION=/tmp/store-copy \
///       xcodebuild test -project PostRollApp/PostRoll.xcodeproj \
///         -scheme PostRollTests \
///         -only-testing:PostRollTests/PhotoPromotionRateMeasurement
@MainActor
final class PhotoPromotionRateMeasurement: XCTestCase {

    private func storeCopy() throws -> URL {
        guard let path = ProcessInfo.processInfo
            .environment["POSTROLL_MEASURE_PROMOTION"], !path.isEmpty else {
            throw XCTSkip("POSTROLL_MEASURE_PROMOTION is not set, so there is "
                          + "no store copy to measure. This reads live data and "
                          + "does nothing without being asked.")
        }
        return URL(fileURLWithPath: path)
    }

    private struct Book: Decodable {
        struct Record: Decodable {
            let handle: String
            let stats: AccountStats?
        }
        let records: [Record]
    }

    func testHowOftenTheSuggestionWouldFire() throws {
        let root = try storeCopy()
        let events = try JSONDecoder().decode(
            [Event].self,
            from: try Data(contentsOf: root.appendingPathComponent("events.json")))
        // The book writes its dates as ISO 8601, which is not the default. A
        // decoder that disagrees with the writer reports a type mismatch on a
        // field this measurement does not even read.
        let bookDecoder = JSONDecoder()
        bookDecoder.dateDecodingStrategy = .iso8601
        let book = try bookDecoder.decode(
            Book.self,
            from: try Data(contentsOf: root.appendingPathComponent("accounts.json")))

        var figures: [String: AccountStats] = [:]
        for record in book.records where record.stats != nil {
            figures[AccountBook.key(record.handle)] = record.stats
        }

        XCTAssertGreaterThan(events.count, 0, "the copy holds no events")
        XCTAssertGreaterThan(figures.count, 0,
                             "no account in the copy carries figures, so the "
                             + "suggestion cannot fire at all and a rate of "
                             + "zero would say nothing about the trigger (L98)")

        let now = Date()
        var days = 0, fired = 0
        // Why a zero is a zero. A rate of nothing has two causes that read
        // alike: the trigger being narrow, and the trigger being unreachable
        // because no photograph carries an account with figures (L98). The
        // second is not a finding about the trigger at all, so the two are
        // counted apart.
        var daysWithAnyTaggedPhoto = 0
        var daysWithTwoRankablePhotos = 0
        for event in events {
            let preset = event.effectivePostingPreset
            for day in DayName.allCases where preset.isCollageCarousel(day) {
                guard let posting = event.days[day.rawValue],
                      posting.photoPaths.count > 1 else { continue }
                days += 1

                let tagsPerPhoto = posting.photoPaths.map {
                    CaptionBlocks.photoTags(posting, for: $0)
                }
                if tagsPerPhoto.contains(where: { !$0.isEmpty }) {
                    daysWithAnyTaggedPhoto += 1
                }
                let rankable = tagsPerPhoto.filter { tags in
                    tags.contains { figures[AccountBook.key($0)] != nil }
                }
                if rankable.count > 1 { daysWithTwoRankablePhotos += 1 }

                if CollaboratorPick.photoToPromote(
                    event: event, day: day, preset: preset,
                    stats: { figures[AccountBook.key($0)] }, asOf: now) != nil {
                    fired += 1
                }
            }
        }

        // Counts only. Printed rather than asserted: this is a reading, and a
        // threshold chosen before taking it would be the second uncalibrated
        // constant #983 declined to add (L172).
        print("""
            PROMOTION RATE: fired on \(fired) of \(days) collage carousel days
              days with any tagged photograph:        \(daysWithAnyTaggedPhoto)
              days with two photographs it can rank:  \(daysWithTwoRankablePhotos)
              events: \(events.count), accounts carrying figures: \(figures.count)
            """)

        XCTAssertGreaterThan(days, 0,
                             "no collage carousel day in the copy has more than "
                             + "one photograph, so the predicate was never "
                             + "reached and the rate is about nothing")
    }
}
