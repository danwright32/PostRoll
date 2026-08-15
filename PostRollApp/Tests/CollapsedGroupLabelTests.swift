import XCTest

/// Every place the app folds a composite view into one VoiceOver element
/// (#608).
///
/// Scoped to the MODIFIER CHAIN rather than the file, which is the whole point:
/// `FindingsPanel.swift` holds two panels, one named and one not, and a check
/// that searched the file would have been answered by the working one while the
/// broken one shipped (L135).
///
/// A chain is a run of lines each beginning with a `.`, plus everything inside
/// a bracket or brace one of them opened, so a modifier wrapped over several
/// lines and a trailing closure both stay attached to the chain they belong to.
enum CollapsedGroup {

    struct Site: Equatable {
        let file: String
        let line: Int
        /// As written, so the message names the mode that was used.
        let mode: String
        var described: String { "\(file):\(line) (\(mode))" }
    }

    /// The modes that leave the group with nothing to say for itself.
    ///
    /// `.combine` is deliberately absent: it merges the children's own labels
    /// into one spoken string, so the name comes from the content and there is
    /// nothing to add. Written here rather than left as a gap in a regular
    /// expression, so the exclusion has a reader (L129).
    private static let silentModes = ["contain", "ignore"]

    private static let collapse =
        try? NSRegularExpression(pattern: #"\.accessibilityElement\(children:\s*\.(\w+)\)"#)

    /// Every collapsed group in `text`, whether or not it is named.
    static func all(in text: String, file: String) -> [Site] {
        chains(in: text).flatMap { $0.sites(file: file) }
    }

    /// The collapsed groups whose own chain never names them.
    static func unlabelled(in text: String, file: String) -> [Site] {
        chains(in: text).flatMap { chain in
            chain.text.contains(".accessibilityLabel(")
                || chain.text.contains(".accessibilityValue(")
                ? [] : chain.sites(file: file)
        }
    }

    // MARK: - Chains

    private struct Chain {
        /// Line numbers are 1 based and are the real ones: comments are
        /// blanked rather than removed, so an offender can be pointed at.
        let numbered: [(line: Int, text: String)]
        var text: String { numbered.map(\.text).joined(separator: "\n") }

        func sites(file: String) -> [Site] {
            numbered.compactMap { entry in
                let range = NSRange(entry.text.startIndex..., in: entry.text)
                guard let match = collapse?.firstMatch(in: entry.text, range: range),
                      let modeRange = Range(match.range(at: 1), in: entry.text)
                else { return nil }
                let mode = String(entry.text[modeRange])
                guard silentModes.contains(mode) else { return nil }
                return Site(file: file, line: entry.line, mode: "children: .\(mode)")
            }
        }
    }

    private static func chains(in text: String) -> [Chain] {
        let lines = SwiftSourceText.withoutComments(text).components(separatedBy: .newlines)
        var chains: [Chain] = []
        var current: [(line: Int, text: String)] = []
        var depth = 0

        func flush() {
            if !current.isEmpty { chains.append(Chain(numbered: current)) }
            current = []
            depth = 0
        }

        for (index, line) in lines.enumerated() {
            let starts = line.trimmingCharacters(in: .whitespaces).hasPrefix(".")
            guard depth > 0 || starts else { flush(); continue }
            current.append((line: index + 1, text: line))
            depth += bracketDelta(line)
            // A chain that closes more than it opened has run past the view it
            // belonged to, so it ends here rather than swallowing what follows.
            if depth < 0 { flush() }
        }
        flush()
        return chains
    }

    /// How much this line opens minus how much it closes, ignoring anything
    /// inside a string literal. A `(` in a piece of copy is not structure.
    private static func bracketDelta(_ line: String) -> Int {
        var delta = 0
        var inString = false
        var escaped = false
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if "([{".contains(character) { delta += 1 }
            if ")]}".contains(character) { delta -= 1 }
        }
        return delta
    }
}

/// #608: a group that collapses its children and says nothing about itself.
///
/// The blog findings panel folded its contents into one VoiceOver element and
/// gave that element no label, so it announced as a group with nothing to say
/// about what the group was. It was found in #603 only because the caption's
/// panel sat beside it in the same file and did have one.
///
/// Nothing would have reported it. `.accessibilityElement(children:)` and
/// `.accessibilityLabel` are unrelated modifiers as far as the compiler is
/// concerned, and a collapsed group with no label is indistinguishable from a
/// group that was never collapsed.
///
/// So the question gets asked of every one. The scan is deliberately scoped to
/// the MODIFIER CHAIN the collapse belongs to, not to the file: the panel that
/// was broken and the panel that was not lived in the same file, and a whole
/// file match would have been answered by the working one (L135).
final class CollapsedGroupLabelTests: XCTestCase {

    /// Collapsed groups whose name genuinely comes from somewhere else, with
    /// the reason.
    ///
    /// Empty today. It exists because the exemption has to be WRITTEN when the
    /// first one arrives, rather than left as a silent hole in the sweep
    /// (L129), and it is checked in both directions below: an entry matching
    /// nothing fails too, because a stale exemption quietly covers whatever
    /// drifts into its place (L96).
    private static let namedElsewhere: [String: String] = [:]

    private static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func sources() throws -> [URL] {
        var urls: [URL] = []
        let files = FileManager.default.enumerator(at: sourcesDir,
                                                   includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "swift" { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }

    // MARK: - The sweep

    func testEveryCollapsedGroupSaysWhatItIs() throws {
        var offenders: [String] = []
        for url in try Self.sources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += CollapsedGroup.unlabelled(in: text, file: url.lastPathComponent)
                .filter { Self.namedElsewhere[$0.file] == nil }
                .map(\.described)
        }

        XCTAssertTrue(offenders.isEmpty, """
            These views fold their contents into one VoiceOver element and give that \
            element no name, so it announces as a group with nothing to say about \
            what the group is:

            \(offenders.joined(separator: "\n"))

            Add `.accessibilityLabel` or `.accessibilityValue` to the same chain, or \
            record it in `namedElsewhere` in this file with where the name does come \
            from.
            """)
    }

    /// A clean tree cannot tell a working matcher from a blind one (#586), and
    /// every collapsed group in the app carries a label today, so the sweep
    /// above is passing on an empty result. This is what says the result is
    /// empty for the right reason.
    func testTheScannerStillFindsTheGroupsInTheTree() throws {
        var found = 0
        for url in try Self.sources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            found += CollapsedGroup.all(in: text, file: url.lastPathComponent).count
        }
        print("  collapsed groups found in Sources: \(found)")
        XCTAssertGreaterThanOrEqual(found, 4, """
            The scanner found \(found) collapsed groups in the whole of Sources, and \
            there were five when this was written. Finding none is not a clean tree, \
            it is a matcher that has gone blind, and the sweep above would report a \
            pass either way (L98).
            """)
    }

    // MARK: - The matcher, proved on synthetic lines

    private func unlabelled(_ source: String) -> [String] {
        CollapsedGroup.unlabelled(in: source, file: "X.swift").map(\.described)
    }

    func testAGroupWithNoNameIsFlagged() {
        XCTAssertEqual(unlabelled("""
            VStack { Text(a); Text(b) }
                .padding()
                .accessibilityElement(children: .contain)
            """).count, 1)
    }

    func testAGroupWithALabelIsNotFlagged() {
        XCTAssertTrue(unlabelled("""
            VStack { Text(a); Text(b) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Checks on the caption")
            """).isEmpty)
    }

    /// A value says what the group holds just as a label says what it is, and
    /// a slider or a status readout is named that way.
    func testAGroupWithAValueIsNotFlagged() {
        XCTAssertTrue(unlabelled("""
            VStack { Text(a) }
                .accessibilityElement(children: .ignore)
                .accessibilityValue("3 of 12")
            """).isEmpty)
    }

    /// The label may be written before the collapse as easily as after it.
    func testTheOrderOfTheTwoModifiersDoesNotMatter() {
        XCTAssertTrue(unlabelled("""
            VStack { Text(a) }
                .accessibilityLabel("Spring Gala")
                .accessibilityElement(children: .ignore)
            """).isEmpty)
    }

    /// A label spread over more than one line is still a label. The one this
    /// guard was written about is exactly that shape.
    func testALabelWrappedOverTwoLinesStillCounts() {
        XCTAssertTrue(unlabelled("""
            VStack { Text(a) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(FindingsDisplay.spokenLabel(subject: subject,
                                                                summary: summary))
            """).isEmpty)
    }

    /// The whole reason this is scoped to the chain (L135). Both panels are in
    /// one file, one of them names itself, and the file-wide version of this
    /// check was answered by the good one while the broken one shipped.
    func testALabelOnADifferentViewInTheSameFileDoesNotCount() {
        XCTAssertEqual(unlabelled("""
            struct CaptionPanel: View {
                var body: some View {
                    VStack { Text(a) }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Checks on the caption")
                }
            }

            struct BlogPanel: View {
                var body: some View {
                    VStack { Text(b) }
                        .accessibilityElement(children: .contain)
                }
            }
            """).count, 1)
    }

    /// `.combine` is the one mode that does not need a label of its own: it
    /// merges the children's labels into a single spoken string, so the name
    /// comes from the content. Written down here rather than left as a silent
    /// gap in the matcher (L129).
    func testCombineIsNotACollapseThatNeedsItsOwnName() {
        XCTAssertTrue(unlabelled("""
            HStack { Text(a); Text(b) }
                .accessibilityElement(children: .combine)
            """).isEmpty)
    }

    /// A comment is not a label. This is the direction where prose makes a
    /// presence check pass (L103).
    func testACommentMentioningALabelDoesNotCount() {
        XCTAssertEqual(unlabelled("""
            VStack { Text(a) }
                .accessibilityElement(children: .contain)
                // TODO: add .accessibilityLabel here
            """).count, 1)
    }

    /// The line the offender is reported on has to be the collapse itself, or
    /// the message sends whoever reads it to the wrong place.
    func testTheOffenderIsReportedAtTheCollapse() {
        XCTAssertEqual(unlabelled("""
            VStack { Text(a) }
                .padding()
                .accessibilityElement(children: .contain)
            """), ["X.swift:3 (children: .contain)"])
    }

    // MARK: - The exemptions are held to the tree

    /// An exemption names a file, and it may cover exactly one group in it.
    ///
    /// Both halves matter. An entry matching nothing has outlived the view it
    /// was written for and covers whatever drifts into its place; an entry
    /// covering two groups is excusing a second one nobody looked at, which is
    /// the same hole one level down (L96).
    func testEveryExemptionCoversExactlyOneGroup() throws {
        var counts: [String: Int] = [:]
        for url in try Self.sources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for group in CollapsedGroup.unlabelled(in: text, file: url.lastPathComponent) {
                counts[group.file, default: 0] += 1
            }
        }

        let wrong = Self.namedElsewhere.keys
            .filter { counts[$0] != 1 }
            .map { "\($0): \(counts[$0] ?? 0) unlabelled groups, expected 1" }

        XCTAssertTrue(wrong.isEmpty, """
            These entries do not cover exactly one unlabelled group. Zero means the \
            exemption has outlived its view and now covers whatever drifts into its \
            place; more than one means it is quietly excusing a group nobody wrote it \
            for:

            \(wrong.sorted().joined(separator: "\n"))
            """)
    }
}
