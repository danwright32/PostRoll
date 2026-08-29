import XCTest

/// Every text field says how it should be drawn (#930).
///
/// A `TextField` with no `.textFieldStyle` gets AppKit's own bezel, drawn
/// INSIDE whatever background the surrounding view specifies. That is what made
/// both tag fields on the posting screen render as near black pills with barely
/// readable text: `HandleField` named `deepPage` for the fill and `bodyText`
/// for the words, both correct, and the screen disagreed anyway (#919, L231).
///
/// No existing check could catch it. The legibility checks read the colours the
/// code NAMES, and the colours are right; only a render shows the bezel, and
/// #919 was found by accident when one panel was put on the review sheet for an
/// unrelated reason.
///
/// So the rule is that the choice is STATED, not that it is any particular one.
/// A field either asks for `.plain`, because it paints its own surface and the
/// platform's would sit on top of it, or asks for the platform look on purpose.
/// What is refused is inheriting it silently, because that is indistinguishable
/// from having decided.
@MainActor
final class TextFieldStyleTests: XCTestCase {

    private static func sources() throws -> [(path: String, lines: [String])] {
        // Appended rather than trimmed off an absolute path, so a checkout
        // under a symlink does not fuse the two (#941, L266).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var found: [(String, [String])] = []
        for case let url as URL in walk! where url.pathExtension == "swift" {
            found.append((url.lastPathComponent,
                          try String(contentsOf: url, encoding: .utf8)
                            .components(separatedBy: "\n")))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// Where a field is declared, and whether its own chain states a style.
    ///
    /// The chain ends at the NEXT field rather than after a fixed number of
    /// lines, so one field's style can never be read as the next one's, which
    /// is the reading that would quietly excuse the field beside a styled one.
    static func fieldsWithoutAStatedStyle(_ lines: [String]) -> [Int] {
        var starts: [Int] = []
        for (i, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
            // A real SwiftUI field, not one of this app's wrappers around one.
            // `BrandTextField` is the app's own component and the style belongs
            // INSIDE it, not at each of its four call sites; a plain substring
            // match reported all four and would have had the rule satisfied in
            // the wrong place.
            if code.range(of: #"(?<![A-Za-z0-9_])(TextField|SecureField)\("#,
                          options: .regularExpression) != nil {
                starts.append(i)
            }
        }

        var missing: [Int] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : min(start + 40, lines.count)
            let chain = lines[start..<end]
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if !chain.contains(".textFieldStyle(") { missing.append(start + 1) }
        }
        return missing
    }

    func testEveryTextFieldSaysHowItShouldBeDrawn() throws {
        var offenders: [String] = []
        for (path, lines) in try Self.sources() {
            for line in Self.fieldsWithoutAStatedStyle(lines) {
                offenders.append("\(path):\(line)")
            }
        }

        XCTAssertEqual(offenders, [], """
            these text fields state no style, so AppKit draws its own bezel \
            inside whatever background the view around them specifies: \
            \(offenders). That is what made the posting screen's tag fields \
            render as near black pills while every colour they named was right \
            (#919). Say `.plain` if the field paints its own surface, or ask for \
            the platform look on purpose.
            """)
    }

    /// The control. A scan that had stopped finding fields would report every
    /// file clean, and its silence would read as the rule holding (L98, L1).
    func testTheScanFindsAFieldThatStatesNothing() {
        let unstyled = ["    TextField(\"a\", text: $a)",
                        "        .font(.system(size: 12))"]

        XCTAssertEqual(Self.fieldsWithoutAStatedStyle(unstyled), [1])
    }

    func testTheScanAcceptsAFieldThatStatesOne() {
        let styled = ["    TextField(\"a\", text: $a)",
                      "        .textFieldStyle(.plain)"]

        XCTAssertEqual(Self.fieldsWithoutAStatedStyle(styled), [])
    }

    func testOneFieldsStyleIsNotReadAsTheNextOnes() {
        // The reading that would quietly excuse a field for sitting next to a
        // styled one, which is the commonest way these are written: several
        // fields in a row inside one container.
        let pair = ["    TextField(\"a\", text: $a)",
                    "    TextField(\"b\", text: $b)",
                    "        .textFieldStyle(.plain)"]

        XCTAssertEqual(Self.fieldsWithoutAStatedStyle(pair), [1],
                       "the first field borrowed the second one's style")
    }

    func testAWrapperAroundAFieldIsNotOneItself() {
        // `BrandTextField` is this app's own component. The style belongs inside
        // it, once, not at every call site, and a substring match reported all
        // four of its uses in NewEventSheet as unstyled fields.
        let wrapped = ["    BrandTextField(\"Event name\", text: $name)",
                       "    BrandSecureField(\"Key\", text: $key)"]

        XCTAssertEqual(Self.fieldsWithoutAStatedStyle(wrapped), [],
                       "a wrapper around a field is being counted as a field, "
                       + "so the rule would be satisfied at the call site rather "
                       + "than where the field actually is")
    }

    func testACommentedOutFieldIsNotCounted() {
        let commented = ["    // TextField(\"a\", text: $a)"]

        XCTAssertEqual(Self.fieldsWithoutAStatedStyle(commented), [])
    }
}
