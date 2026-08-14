import XCTest

/// #465: an icon with no name is a control VoiceOver can only call "button".
///
/// The fix for this class already existed in the app: the blog metadata copy
/// button and the event list toolbar buttons carry labels. It had simply
/// skipped its siblings, which is how a fixed class comes back (L30): three
/// caption copy buttons, two open-at-full-size buttons, three menu triggers,
/// the carousel arrows and a preset delete, all icon only and all unnamed.
///
/// So the question gets asked of every one instead. A control whose entire
/// visible content is an SF Symbol has to carry an `accessibilityLabel`, or be
/// named here as decorative with the reason.
final class IconOnlyControlLabelTests: XCTestCase {

    /// How far after a control's opening line a label may appear. Generous:
    /// the label lands after the closing brace of the button's own body, and
    /// an icon-only body with padding, background and clip shape is a dozen
    /// lines on its own.
    private static let window = 30

    /// Controls whose icon genuinely needs no name, with the reason.
    ///
    /// Checked in both directions: an entry matching nothing fails too,
    /// because a stale exemption quietly covers whatever drifts into its
    /// place (L96).
    private static let decorative: [String: String] = [:]

    private static var viewsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
    }

    private static func viewSources() throws -> [URL] {
        var urls: [URL] = []
        let files = FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "swift" { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// A control declaration whose visible body is only an SF Symbol.
    struct IconOnlyControl: Equatable {
        let file: String
        let line: Int
        let symbol: String
        var described: String { "\(file):\(line) (\(symbol))" }
    }

    /// Every `Button`/`Menu` in `text` whose label draws an SF Symbol and no
    /// text, together with whether a label follows it.
    ///
    /// Line based, over source with its comments blanked, so a comment
    /// mentioning `accessibilityLabel` cannot answer for one. This is a
    /// PRESENCE check, which is the direction where prose makes it pass
    /// (L103).
    static func unlabelledIconControls(in text: String, file: String) -> [IconOnlyControl] {
        let lines = SwiftSourceText.withoutComments(text)
            .components(separatedBy: .newlines)
        var found: [IconOnlyControl] = []

        for (index, line) in lines.enumerated() {
            guard line.contains("Image(systemName:") else { continue }
            // The symbol name, for a message that says which control.
            let symbol = line.range(of: #"Image\(systemName: "[^"]+""#, options: .regularExpression)
                .map { String(line[$0]).components(separatedBy: "\"")[1] } ?? "?"

            // Is this image the label of a control? Look back for the opening
            // of a Button or Menu whose body has not yet drawn any text.
            var opener: Int? = nil
            var sawText = false
            for back in stride(from: index, through: max(0, index - 12), by: -1) {
                let candidate = lines[back]
                if candidate.contains("Text(") || candidate.contains("Label(") { sawText = true }
                if candidate.contains("} label: {")
                    || candidate.range(of: #"\b(Button|Menu)\s*(\(action:)?.*\{\s*$"#,
                                       options: .regularExpression) != nil {
                    opener = back
                    break
                }
            }
            guard let opener, !sawText else { continue }

            // Does anything in reach name it?
            let reach = lines[opener..<min(lines.count, index + window)].joined(separator: "\n")
            if reach.contains(".accessibilityLabel(")
                || reach.contains(".accessibilityHidden(true)")
                || reach.contains("Text(") || reach.contains("Label(") {
                continue
            }
            found.append(IconOnlyControl(file: file, line: index + 1, symbol: symbol))
        }
        return found
    }

    private static func exemption(for control: IconOnlyControl) -> String? {
        decorative.first { key, _ in
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return control.file.contains(parts[0]) && control.symbol == parts[1]
        }?.value
    }

    func testEveryIconOnlyControlCarriesAName() throws {
        var offenders: [String] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.unlabelledIconControls(in: text, file: url.lastPathComponent)
                .filter { Self.exemption(for: $0) == nil }
                .map(\.described)
        }

        XCTAssertTrue(offenders.isEmpty, """
            These controls draw an SF Symbol and nothing else, and carry no name, \
            so VoiceOver can only announce them as "button" and a tooltip is the \
            only thing that says what they do.

            Add `.accessibilityLabel("…")` saying what pressing it does, or add it \
            to `decorative` in this file with the reason its icon needs no name:

            \(offenders.joined(separator: "\n"))
            """)
    }

    func testTheScannerCanStillSeeControls() throws {
        // Finding none at all would pass the assertion above while checking
        // nothing (L98). The tree is full of icon-only controls; what the
        // scanner has to keep finding is the shape.
        let source = """
        Button { doIt() } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        """
        XCTAssertEqual(Self.unlabelledIconControls(in: source, file: "X.swift").count, 1)
    }

    func testALabelledControlIsNotFlagged() {
        let source = """
        Button { doIt() } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Delete this preset")
        """
        XCTAssertTrue(Self.unlabelledIconControls(in: source, file: "X.swift").isEmpty)
    }

    /// A comment is not a label. This is the direction where prose makes a
    /// presence check pass (L103).
    func testACommentMentioningALabelDoesNotCount() {
        let source = """
        Button { doIt() } label: {
            Image(systemName: "trash")
        }
        // TODO: add .accessibilityLabel here
        """
        XCTAssertEqual(Self.unlabelledIconControls(in: source, file: "X.swift").count, 1)
    }

    func testAControlThatAlsoDrawsTextIsNotIconOnly() {
        let source = """
        Button { doIt() } label: {
            Image(systemName: "trash")
            Text("Delete")
        }
        """
        XCTAssertTrue(Self.unlabelledIconControls(in: source, file: "X.swift").isEmpty)
    }

    func testEveryDecorativeEntryStillMatchesSomething() throws {
        var seen: [IconOnlyControl] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            seen += Self.unlabelledIconControls(in: text, file: url.lastPathComponent)
        }

        let stale = Self.decorative.keys.filter { key in
            !seen.contains { Self.exemption(for: $0) != nil && exemptionKey(key, matches: $0) }
        }

        XCTAssertTrue(stale.isEmpty, """
            These entries no longer match any control. An exemption that has \
            outlived its icon quietly covers whatever drifts into its place, so \
            delete them:

            \(stale.joined(separator: "\n"))
            """)
    }

    private func exemptionKey(_ key: String, matches control: IconOnlyControl) -> Bool {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return control.file.contains(parts[0]) && control.symbol == parts[1]
    }
}
