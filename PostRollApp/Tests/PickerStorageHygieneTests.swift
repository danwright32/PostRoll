import XCTest

/// #146: a file picked with NSOpenPanel must be copied into app storage before
/// its path is persisted on an Event.
///
/// macOS grants access to ~/Downloads, ~/Desktop and the like per app launch,
/// so a raw picked path works today and is unreadable after the next launch.
/// Two bugs on 2026-07-08 shared exactly this cause, one in new code and one
/// pre-existing, and the audit that followed could only ever be true on the day
/// it was run. This is that audit as a standing check.
///
/// Deliberately a source scan rather than a behavioural test: the defect is a
/// call site forgetting a step, so what has to be enforced is that no call site
/// can forget it.
final class PickerStorageHygieneTests: XCTestCase {

    /// Any of these near a picker means the pick is being brought into storage.
    private let storageHelpers = [
        "storedPick", "storedPicks", "storedPhoto", "storedClip", "storedAudio",
        "ImportedPicks.copy", "importedCopy", "importedCopyResult",
    ]

    /// Call sites that legitimately never persist a path, with the reason.
    /// Named individually so a new picker cannot inherit an exemption.
    private let exempt: [String: String] = [
        "InsightsOverviewView.swift": """
            The Meta CSV import hands the picked files straight to Python and \
            keeps nothing: the rows are read out and stored, the file path is \
            not. There is no path to go stale.
            """,
    ]

    private func viewSources() throws -> [URL] {
        let viewsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // PostRollApp
            .appendingPathComponent("Sources/Views")
        let all = FileManager.default.enumerator(at: viewsDir,
                                                 includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return all.sorted { $0.path < $1.path }
    }

    /// Names of functions in `text` with a storage helper in the lines that
    /// follow their declaration.
    ///
    /// Deliberately a lookahead rather than real scope parsing. Two shapes
    /// broke the parsed version: a one-line function body, and a nested helper
    /// (`handlePickedFiles` wraps an inner `func store`) whose storage call got
    /// attributed to the inner name, so the outer one looked like it stored
    /// nothing. This only has to tell "stores somewhere near" from "stores
    /// nowhere at all", which is the actual defect.
    static func functionsThatStore(in text: String, helpers: [String],
                                   lookahead: Int = 60) -> Set<String> {
        var found: Set<String> = []
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: "func ") else { continue }
            let name = line[range.upperBound...]
                .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            // From this line (so a one-line body counts) forward.
            let window = lines[index..<min(lines.count, index + lookahead)]
                .joined(separator: "\n")
            if helpers.contains(where: window.contains) { found.insert(name) }
        }
        return found
    }

    func testTheScanFindsTheFilesItIsSupposedTo() throws {
        // A scan that silently matched nothing would pass forever.
        let withPickers = try viewSources().filter {
            ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("NSOpenPanel()")
        }
        XCTAssertGreaterThanOrEqual(withPickers.count, 3,
                                    "expected several files with pickers, found \(withPickers.count)")
    }

    func testEveryPickerRoutesItsPickIntoAppStorage() throws {
        var offenders: [String] = []

        for file in try viewSources() {
            let name = file.lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)

            // Functions in this file that DO store, so a picker handing its
            // result to one of them counts. Several pickers are two lines that
            // delegate immediately (importFromFolder, handlePickedFiles), and
            // without following that hop the check would report them as
            // offenders and get switched off.
            let storingFunctions = Self.functionsThatStore(in: text, helpers: storageHelpers)

            for (index, line) in lines.enumerated() where line.contains("NSOpenPanel()") {
                if exempt[name] != nil { continue }
                // The storage step happens near the pick, either just before
                // (a helper the panel result is handed to) or just after.
                let window = lines[max(0, index - 10)..<min(lines.count, index + 45)]
                    .joined(separator: "\n")
                let storesHere = storageHelpers.contains(where: window.contains)
                let handsOff = storingFunctions.contains { window.contains($0 + "(") }
                if !storesHere && !handsOff {
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These NSOpenPanel call sites do not route the pick through app \
            storage within sight of the picker: \(offenders.joined(separator: ", ")).
            A raw picked path reads fine now and is unreadable after the next \
            launch, because macOS grants access to folders like ~/Downloads per \
            app launch. Copy it with AppPaths.stored* or ImportedPicks.copy \
            before it reaches the Event, or add the file to `exempt` with the \
            reason it keeps no path.
            """)
    }

    func testFollowingAHandOffDoesNotExcuseAFunctionThatStoresNothing() {
        // The hop-following must not degrade into "any function call counts".
        let source = """
        func pickIt() {
            let panel = NSOpenPanel()
            doSomethingElse(panel.url)
        }
        func doSomethingElse(_ u: URL) { event.path = u }
        """
        let storing = Self.functionsThatStore(in: source, helpers: storageHelpers)
        XCTAssertTrue(storing.isEmpty, "nothing here stores, so nothing may be excused")
    }

    func testAHandOffToAStoringFunctionIsRecognised() {
        let source = """
        func pickIt() {
            let panel = NSOpenPanel()
            handlePickedFiles(panel.urls)
        }
        func handlePickedFiles(_ urls: [URL]) { AppPaths.storedPhoto(urls[0]) }
        """
        let storing = Self.functionsThatStore(in: source, helpers: storageHelpers)
        XCTAssertTrue(storing.contains("handlePickedFiles"), "\(storing)")
    }

    func testAnExemptionMustCarryAReason() {
        for (file, reason) in exempt {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(file) is exempt with no reason recorded")
        }
    }

    func testAnExemptFileStillHasToExist() throws {
        let names = Set(try viewSources().map(\.lastPathComponent))
        for file in exempt.keys {
            XCTAssertTrue(names.contains(file),
                          "\(file) is exempt but no longer exists; drop the exemption")
        }
    }
}
