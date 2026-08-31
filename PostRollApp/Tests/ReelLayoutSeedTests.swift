import XCTest

/// #1062: a Thursday reel's masonry layout is decided once and written down.
///
/// `reelSeed` was minted only when Dan pressed "New layout", so a reel nobody
/// had asked to reshuffle never got a seed at all. `build_collage_strip` then
/// called `random.Random(None)`, which seeds from system entropy, and every
/// render laid out all 234 photographs differently: adjusting one crop
/// re-shuffled the whole reel.
///
/// It also made `SpeculativeReelRenderer` wrong in a way its own comment
/// denied. That comment calls the reel a pure function of five inputs while one
/// of them was absent, so a background pre-render and the render it was adopted
/// for could be two different collages, and the adopted one is the reel Dan
/// never saw.
///
/// Measured in the live store on 2026-08-31: 19 of 21 Thursday days carry no
/// seed.
@MainActor
final class ReelLayoutSeedTests: XCTestCase {

    private func thursday(seed: Int? = nil, photos: Int = 3) -> PostingDay {
        var pd = PostingDay(day: .thursday)
        pd.reelSeed = seed
        pd.photoPaths = (0..<photos).map { URL(fileURLWithPath: "/tmp/reel-\($0).jpg") }
        return pd
    }

    private func event(_ day: PostingDay) -> Event {
        var event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(timeIntervalSince1970: 1_775_000_000),
                          shootType: .fullShow)
        event.days = [DayName.thursday.rawValue: day]
        return event
    }

    // MARK: - Minting

    func testADayWithNoSeedGetsOne() {
        var pd = thursday()
        XCTAssertEqual(pd.ensureReelSeed(using: { 4242 }), 4242)
        XCTAssertEqual(pd.reelSeed, 4242, "the seed was returned and not stored")
    }

    func testADayThatAlreadyHasASeedKeepsIt() {
        // The whole point of storing it. Minting again on every render would be
        // the same reshuffle wearing a stored value.
        var pd = thursday(seed: 111)
        XCTAssertEqual(pd.ensureReelSeed(using: { 4242 }), 111)
        XCTAssertEqual(pd.reelSeed, 111)
    }

    func testAskingForANewLayoutReplacesTheSeed() {
        var pd = thursday(seed: 111)
        XCTAssertEqual(pd.ensureReelSeed(fresh: true, using: { 4242 }), 4242)
        XCTAssertEqual(pd.reelSeed, 4242)
    }

    func testAFreshSeedIsMintedForADayThatHadNoneEither() {
        // `fresh` must not depend on there being something to replace.
        var pd = thursday()
        XCTAssertEqual(pd.ensureReelSeed(fresh: true, using: { 4242 }), 4242)
    }

    // MARK: - Nothing is pre-rendered against an undecided layout

    func testAReelWithNoSeedIsNotFingerprintedAtAll() {
        // Not fingerprinted as "seed:nil": that string is the same for two
        // renders that produce different collages, so a pre-render taken under
        // one would be adopted for the other (L75).
        let renderer = SpeculativeReelRenderer()
        XCTAssertNil(renderer.fingerprint(for: event(thursday())))
    }

    func testAReelWithASeedIsFingerprinted() {
        // The positive control. Without it the assertion above is satisfied by
        // a fingerprint that refuses everything (L159).
        let renderer = SpeculativeReelRenderer()
        XCTAssertNotNil(renderer.fingerprint(for: event(thursday(seed: 111))))
    }

    func testTwoSeedsFingerprintDifferently() {
        // The seed has to be IN the fingerprint, not merely required by it.
        let renderer = SpeculativeReelRenderer()
        XCTAssertNotEqual(renderer.fingerprint(for: event(thursday(seed: 111))),
                          renderer.fingerprint(for: event(thursday(seed: 222))))
    }
}
