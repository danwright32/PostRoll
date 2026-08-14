import XCTest

/// #483: the account book records tags that actually shipped.
///
/// It was stamped at the START of the export, before the text export or any
/// asset copy ran, and a failed export never rolled it back. So the book
/// recorded a week's tags as sent when nothing had been written to disk, and
/// the recurring-account freshness stats it feeds were reading from a
/// non-event. Record intent, confirm after the effect verifiably happened
/// (L33); here the confirmation is the record.
///
/// A source check rather than a behavioural one, because what changed is
/// WHERE the write happens: `ExportManager` runs a real export against a real
/// folder and a test that exercised the ordering would have to do the same.
/// What has to be enforced is that the write cannot drift back above the work
/// it is supposed to be confirming.
final class TaggedHandlesStampedOnSuccessTests: XCTestCase {

    private var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Services/ExportManager.swift")
            // Comments blanked, so prose about the write cannot answer for the
            // write and a comment cannot fail this either (L103).
            return SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
        }
    }

    /// The body of one `private func` in ExportManager, by name.
    private func body(of function: String, in text: String) throws -> String {
        let marker = "func \(function)("
        guard let start = text.range(of: marker) else {
            throw XCTSkip("ExportManager has no \(function); this guard is checking nothing")
        }
        let rest = text[start.lowerBound...]
        var depth = 0
        var seenBrace = false
        var out = ""
        for character in rest {
            out.append(character)
            if character == "{" { depth += 1; seenBrace = true }
            if character == "}" {
                depth -= 1
                if seenBrace && depth == 0 { break }
            }
        }
        return out
    }

    func testTheBookIsStampedFromTheSuccessPathOnly() throws {
        let text = try source
        let applications = text.components(separatedBy: ".apply(to: AccountBook.shared)").count - 1

        XCTAssertEqual(applications, 1, """
            ExportManager applies the tag stamp \(applications) times. It must apply \
            it exactly once, from the path that runs after the export has committed, \
            or a failed export leaves the book recording tags that never shipped.
            """)

        let success = try body(of: "finishSuccess", in: text)
        XCTAssertTrue(success.contains(".apply(to: AccountBook.shared)"), """
            The tag stamp is applied somewhere other than finishSuccess, so the book \
            records tags before the export has written anything. A run that dies \
            part way then leaves the book claiming a week that never shipped, and \
            nothing rolls it back (#483).
            """)

        XCTAssertFalse(text.contains("AccountBook.shared.noteTagged"), """
            ExportManager writes the account book directly rather than through the \
            stamp, so the write is no longer tied to the export having committed.
            """)
    }

    /// The handles are still worked out from the event as it stands when the
    /// run starts, not from whatever it looks like by the time the export
    /// finishes, which may be minutes and several edits later.
    func testTheHandlesAreReadBeforeTheExportRuns() throws {
        let text = try source
        guard let read = text.range(of: "CaptionBlocks.accountsTagged"),
              let written = text.range(of: ".apply(to: AccountBook.shared)") else {
            return XCTFail("neither the read nor the write is in ExportManager any more")
        }

        XCTAssertLessThan(read.lowerBound, written.lowerBound,
                          "the tagged handles are read after the book is written")
    }
}
