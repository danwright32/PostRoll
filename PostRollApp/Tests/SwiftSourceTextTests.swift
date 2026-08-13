import XCTest

/// Reading Swift source the way the compiler does, for the guards that scan it
/// (#437).
///
/// A source-scanning guard that keeps the comments can be satisfied by prose.
/// That is harmless in one direction and not in the other: a guard looking for
/// something FORBIDDEN goes red on a comment, which is annoying, while a
/// guard looking for something REQUIRED goes green on a comment, which is the
/// check quietly switching itself off. `PickerStorageHygieneTests` is the
/// second kind: a TODO naming `storedPicks` within sight of an `NSOpenPanel()`
/// counted as the storage step having happened, so a picker that genuinely
/// stored nothing would pass (L103).
///
/// Comment text is blanked rather than removed, so line numbers survive and a
/// guard can still report where an offender is.
///
/// The Python side has the same thing in `tests/source_text.py`, for the parity
/// guards that read Swift declarations out of these same files (#436).
enum SwiftSourceText {

    /// `source` with every comment blanked out, string literals left alone.
    ///
    /// A `//` inside `"https://…"` is not a comment, and blanking it would
    /// corrupt exactly the declarations these guards read.
    static func withoutComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)

        var chars = Array(source)
        var i = 0
        var blockDepth = 0
        var inString = false

        func pair(_ at: Int) -> String {
            at + 1 < chars.count ? String(chars[at...(at + 1)]) : String(chars[at])
        }

        while i < chars.count {
            let char = chars[i]

            if blockDepth > 0 {
                if pair(i) == "/*" { blockDepth += 1; out += "  "; i += 2; continue }
                if pair(i) == "*/" { blockDepth -= 1; out += "  "; i += 2; continue }
                out.append(char == "\n" ? "\n" : " ")
                i += 1
                continue
            }

            if inString {
                out.append(char)
                if char == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                // An unterminated literal ends at the newline rather than
                // swallowing the rest of the file.
                if char == "\"" || char == "\n" { inString = false }
                i += 1
                continue
            }

            if char == "\"" { inString = true; out.append(char); i += 1; continue }

            if pair(i) == "//" {
                while i < chars.count, chars[i] != "\n" { out.append(" "); i += 1 }
                continue
            }

            if pair(i) == "/*" { blockDepth = 1; out += "  "; i += 2; continue }

            out.append(char)
            i += 1
        }
        return out
    }
}

final class SwiftSourceTextTests: XCTestCase {

    func testALineCommentIsGone() {
        let stripped = SwiftSourceText.withoutComments("let x = 1 // storedPicks\n")
        XCTAssertFalse(stripped.contains("storedPicks"))
        XCTAssertTrue(stripped.contains("let x = 1"))
    }

    /// The exact shape of #437: a note ABOUT the storage helper reading as the
    /// storage helper.
    func testATodoNamingAHelperCannotStandInForTheHelper() {
        let source = """
        // TODO: route this through AppPaths.storedPicks one day
        let panel = NSOpenPanel()
        """
        XCTAssertFalse(SwiftSourceText.withoutComments(source).contains("storedPicks"))
        XCTAssertTrue(SwiftSourceText.withoutComments(source).contains("NSOpenPanel()"))
    }

    func testABlockCommentIsGoneAndNestingIsFollowed() {
        let stripped = SwiftSourceText.withoutComments(
            "let a = 1 /* outer /* inner */ still comment */ let b = 2\n")
        XCTAssertFalse(stripped.contains("still comment"))
        XCTAssertTrue(stripped.contains("let a = 1"))
        XCTAssertTrue(stripped.contains("let b = 2"))
    }

    func testADoubleSlashInsideAStringSurvives() {
        let source = "let site = \"https://dwphoto.ny\"\n"
        XCTAssertEqual(SwiftSourceText.withoutComments(source), source)
    }

    func testAnEscapedQuoteDoesNotEndTheString() {
        let source = "let q = \"she said \\\"no // yes\\\"\" // trailing\n"
        let stripped = SwiftSourceText.withoutComments(source)
        XCTAssertTrue(stripped.contains("no // yes"))
        XCTAssertFalse(stripped.contains("trailing"))
    }

    /// Guards report offenders by line number, so the file has to keep its
    /// shape rather than closing up.
    func testLinesKeepTheirPositions() {
        let source = "one\n// two\nthree\n"
        XCTAssertEqual(SwiftSourceText.withoutComments(source).components(separatedBy: "\n").count,
                       source.components(separatedBy: "\n").count)
    }

    func testSourceWithNoCommentsComesBackUnchanged() {
        let source = "enum A {\n    static let n = 4\n}\n"
        XCTAssertEqual(SwiftSourceText.withoutComments(source), source)
    }
}
