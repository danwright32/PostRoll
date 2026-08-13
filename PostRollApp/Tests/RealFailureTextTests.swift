import XCTest

/// #403: the classifier, judged against text the pipeline really produces.
///
/// Every needle in `RunFailureKind` came from what a developer imagined Python
/// writes. These read `tests/fixtures/real_failure_text.json`, which was measured
/// on 2026-08-12 by causing each failure against the real pipeline, and assert
/// the classification each one gets.
///
/// This is the check that the invented version was structurally unable to be: a
/// test that feeds the classifier the string it was written to expect agrees with
/// its author, not with the world.
final class RealFailureTextTests: XCTestCase {

    private struct Case: Decodable {
        let name: String
        let provenance: String
        let expected: String
        let text: String
        var note: String?
    }

    private struct Fixture: Decodable {
        let cases: [Case]
    }

    /// Through `RepoFixture` so a folder macOS refuses reports as a permissions
    /// problem rather than as this suite being broken (#271).
    private func loadCases() throws -> [Case] {
        let data = try RepoFixture.data("tests/fixtures/real_failure_text.json")
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    /// Maps the fixture's name for a kind onto the kind, so the fixture does not
    /// have to know Swift's spelling of an associated value.
    private func kindName(_ kind: RunFailureKind) -> String {
        switch kind {
        case .ffmpegMissing:            return "ffmpegMissing"
        case .audioServiceUnreachable:  return "audioServiceUnreachable"
        case .requestTooLarge:          return "requestTooLarge"
        case .rateLimited:              return "rateLimited"
        case .overloaded:               return "overloaded"
        case .authFailed:               return "authFailed"
        case .aiServiceError:           return "aiServiceError"
        case .outputUnreadable:         return "outputUnreadable"
        case .fileMissing:              return "fileMissing"
        case .beforeAfterInputsMissing: return "beforeAfterInputsMissing"
        case .reelPhotosMissing:        return "reelPhotosMissing"
        case .storyFallbackFailed:      return "storyFallbackFailed"
        case .unknown:                  return "unknown"
        }
    }

    func testTheFixtureIsActuallyThere() throws {
        let cases = try loadCases()
        XCTAssertGreaterThan(cases.count, 8,
                             "the fixture is missing or nearly empty, so these checks would "
                             + "pass while measuring nothing")
    }

    /// Every entry claiming to be captured has to be, or this whole file is
    /// invented data wearing a fixture's name (L48).
    func testEveryEntryDeclaresHowItWasObtained() throws {
        let allowed = Set(["captured", "sdk-formatter"])
        for c in try loadCases() {
            XCTAssertTrue(allowed.contains(c.provenance),
                          "\"\(c.name)\" claims provenance \"\(c.provenance)\", which is not "
                          + "one of \(allowed.sorted())")
        }
    }

    /// The measurement itself: real text in, the right kind out.
    func testRealFailureTextClassifiesCorrectly() throws {
        var wrong: [String] = []
        for c in try loadCases() {
            let got = kindName(RunFailureKind.of(c.text))
            if got != c.expected {
                wrong.append("""
                    \(c.name) [\(c.provenance)]
                      expected: \(c.expected)
                      got:      \(got)
                      text:     \(c.text.prefix(140))
                    """)
            }
        }
        XCTAssertTrue(wrong.isEmpty, """
            Real failure text landed in the wrong branch, so the advice Dan reads \
            for these is wrong:

            \(wrong.joined(separator: "\n\n"))
            """)
    }

    /// The consequence, checked separately: whether Dan is offered a route back to
    /// change his inputs. Getting this wrong sends him to change things that were
    /// never the problem, or hides the route when they were.
    func testTheRouteBackIsOfferedForExactlyTheFixableRealFailures() throws {
        let shouldBeFixable = Set([
            "ffmpeg is installed, ran, and failed because an input file was gone",
            "a photo that has been moved or deleted",
            "more content than the model will accept",
            "a payload over the request size limit",
            "a crash in our own code",
        ])
        for c in try loadCases() {
            let fixable = RunFailureKind.of(c.text).isFixableFromTheApp
            XCTAssertEqual(fixable, shouldBeFixable.contains(c.name),
                           "\"\(c.name)\" offers the route back: \(fixable)")
        }
    }
}
