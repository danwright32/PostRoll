import XCTest

/// #362: two issues in one sweep, #357 and #360, were the same shape.
///
/// A call that PRODUCES a file, run behind `try?` so its failure is thrown
/// away, on a path that then carries on as though the file were there. #357
/// returned success from an export that had copied nothing and had already
/// deleted what was there before; #360 handed Python the path of a file it had
/// failed to write. Both read as ordinary defensive code, and both were found
/// by a person reading rather than by anything failing.
///
/// So the pattern gets a guard. Deliberately narrow: `removeItem` and
/// `createDirectory` behind `try?` are ordinary cleanup and there are around
/// seventy-five of them, while the calls that MAKE a file something later
/// depends on are few enough to name every one.
///
/// Anything genuinely best-effort goes on the allowlist with the reason
/// written down, so the next reader sees a decision rather than an oversight
/// (L65). The allowlist is checked in both directions: an entry that no longer
/// matches anything fails too, because a stale allowlist quietly exempts
/// whatever drifts into its place (L96).
final class DiscardedFileWriteGuardTests: XCTestCase {

    /// Calls whose whole purpose is to leave a file behind.
    ///
    /// The leading dot matters and is not decoration: `removeItem` ends with
    /// the whole of `moveItem`, so matching the bare name flags every cleanup
    /// line in the tree. The first version of this guard did exactly that.
    private static let producingCalls = [".copyItem(", ".moveItem(", ".replaceItemAt(", ".write(to:"]

    /// Modifiers a function declaration may carry before `func`.
    ///
    /// A line is only read as a declaration when everything before `func` is
    /// one of these, so `func` appearing inside a closure, a string or a
    /// trailing expression is not mistaken for one.
    private static let declarationModifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "package",
        "static", "class", "final", "override", "mutating", "nonisolated",
        "@MainActor", "@discardableResult", "@objc", "@inlinable", "@nonobjc",
    ]

    /// `file:line-fragment` -> why discarding this one is the right call.
    ///
    /// Every entry is a promise that nothing downstream treats the file as
    /// guaranteed. Adding one is a decision to be argued for, not a way past
    /// this test.
    private static let allowed: [String: String] = [
        "DataMigration.swift|fm.copyItem(at: oldAnalytics, to: newAnalytics)":
            "Analytics history is a nice-to-have during the data move and is explicitly "
            + "excluded from what decides the migration succeeded. Losing it costs past "
            + "numbers, never the events or photos.",

        "PythonBridgeError.swift|kept.write(to: sharedLog, atomically: true, encoding: .utf8)":
            "Rotating the shared log. A failure leaves a larger log, which is the "
            + "harmless direction, and reporting it would need the very log being rotated.",

        "PythonBridgeError.swift|data.write(to: sharedLog)":
            "Folding a finished run's stderr into the shared log. The run's own file is "
            + "read first and this is the archival copy, so a failure loses history "
            + "rather than the error being reported.",

        "AppPaths.swift|fm.copyItem(at: seed, to: dest)":
            "Seeding the editable brand voice on first launch. Guarded by the destination "
            + "being absent, and every reader falls back to the copy packaged in the app, "
            + "so a failure means Dan cannot edit it yet rather than that it is missing.",

        "ArchiveCleanup.swift|Data(line.utf8).write(to: url)":
            "The fallback branch of an audit-log append, taken only when the file could "
            + "not be opened for writing. Nothing reads the audit log to decide anything; "
            + "it exists for Dan to read by hand.",

        "ProgramPDFBuilder.swift|FileManager.default.copyItem(at: url, to: retainedSource)":
            "Retaining the original PDF beside its rasterised pages. The pages are the "
            + "return value and do not depend on it; a failure costs the ability to "
            + "re-rasterise later from the retained copy.",
    ]

    private static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// Every Swift file under Sources.
    private static func sourceFiles() throws -> [URL] {
        var urls: [URL] = []
        let files = FileManager.default.enumerator(at: sourcesDir,
                                                   includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "swift" { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// The function name a line declares, if the line is a declaration.
    private static func declaredFunctionName(_ line: String) -> String? {
        guard let range = line.range(of: #"\bfunc\s+[A-Za-z0-9_]+"#,
                                     options: .regularExpression) else { return nil }
        for token in line[line.startIndex..<range.lowerBound].split(separator: " ") {
            guard declarationModifiers.contains(String(token)) else { return nil }
        }
        return line[range].split(separator: " ").last.map(String.init)
    }

    /// Throwing functions declared in Sources whose own body produces a file.
    ///
    /// This is the half #462 slipped through and #526 closes. The guard used to
    /// look at one physical line, so `try? fm.copyItem(…)` was caught and
    /// `try? bridge.appendBrandVoiceNote(…)` was not, even though the second is
    /// the first with a function call in front of it. Four sites survived on
    /// exactly that difference: they discarded a throwing write one level deep
    /// and then told Dan the note had been saved.
    ///
    /// Deliberately one level, not the transitive closure. Following calls all
    /// the way down reaches around a hundred and forty names, including `save`,
    /// `load`, `open` and `commit`, and a bare name that common collides with
    /// unrelated APIs (`handle.write(contentsOf:)`, `asset.load(.duration)`) and
    /// turns the guard into noise. One level is the wrapper somebody wrote to
    /// do the writing, which is the thing being hidden.
    private static func fileProducingWrappers() throws -> Set<String> {
        var names: Set<String> = []
        for url in try sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var i = 0
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"),
                      let name = declaredFunctionName(trimmed) else { i += 1; continue }

                // The signature runs to the first brace, which may be several
                // lines down when the parameters are wrapped.
                var header = ""
                var open = i
                while open < lines.count {
                    header += lines[open]
                    if lines[open].contains("{") { break }
                    open += 1
                }
                guard open < lines.count else { break }

                var depth = 0
                var body = ""
                var end = open
                while end < lines.count {
                    depth += lines[end].filter { $0 == "{" }.count
                    depth -= lines[end].filter { $0 == "}" }.count
                    body += lines[end] + "\n"
                    end += 1
                    if depth <= 0 { break }
                }

                if header.contains("throws"),
                   producingCalls.contains(where: { body.contains($0) }) {
                    names.insert(name)
                }
                i = max(end, i + 1)
            }
        }
        return names
    }

    /// Every `try?` in Sources sitting on a file-producing call, as
    /// `file|trimmed line`.
    private static func discardedProducingWrites() throws -> [String] {
        let wrappers = try fileProducingWrappers()
        var found: [String] = []
        for url in try sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // A comment ABOUT the pattern is not the pattern. A guard that
                // matches prose is indistinguishable from one that works (L103).
                guard !line.hasPrefix("//"), !line.hasPrefix("///"), !line.hasPrefix("*") else { continue }
                guard line.contains("try?") else { continue }
                let direct = producingCalls.contains { line.contains($0) }
                let wrapped = wrappers.contains { name in
                    line.range(of: "\\b\(name)\\s*\\(", options: .regularExpression) != nil
                }
                guard direct || wrapped else { continue }
                found.append("\(url.lastPathComponent)|\(line)")
            }
        }
        return found
    }

    private static func allowedReason(for occurrence: String) -> String? {
        allowed.first { key, _ in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return occurrence.hasPrefix(parts[0] + "|") && occurrence.contains(parts[1])
        }?.value
    }

    func testNoFileProducingWriteHasItsFailureThrownAway() throws {
        let offenders = try Self.discardedProducingWrites()
            .filter { Self.allowedReason(for: $0) == nil }

        XCTAssertTrue(offenders.isEmpty, """
            A call that creates a file is behind `try?`, so whatever comes next \
            proceeds as though the file is there when it may not be. This is what \
            #357 and #360 both were.

            Handle the failure, or add it to `allowed` in this file with the reason \
            it is genuinely best-effort:

            \(offenders.joined(separator: "\n"))
            """)
    }

    func testEveryAllowlistEntryStillMatchesSomething() throws {
        let occurrences = try Self.discardedProducingWrites()

        let stale = Self.allowed.keys.filter { key in
            !occurrences.contains { Self.allowedReason(for: $0) != nil && matches(key, $0) }
        }

        XCTAssertTrue(stale.isEmpty, """
            These allowlist entries no longer match any code. An entry that has \
            outlived its line silently exempts whatever drifts into its place, so \
            delete them:

            \(stale.joined(separator: "\n"))
            """)
    }

    func testTheGuardActuallyFindsThisPattern() throws {
        // The guard is only worth having if it can see the thing it looks for.
        // Every allowlisted site is a real occurrence, so an empty scan means
        // the scanner is broken rather than the tree being clean (L98: finding
        // nothing must not read as everything passing).
        let occurrences = try Self.discardedProducingWrites()

        XCTAssertFalse(occurrences.isEmpty,
                       "the scanner found nothing at all, which means it stopped working")
        XCTAssertGreaterThanOrEqual(occurrences.count, Self.allowed.count)
    }

    /// The wrapper half has to be able to see wrappers.
    ///
    /// Finding none would leave every assertion above green while the widened
    /// guard checked nothing at all, which is the shape it exists to close
    /// (L98). Asserted as "it still finds several", not as a pinned list: a
    /// pinned list would need editing every time a function is renamed, and
    /// each edit is a chance to pin the empty answer (L63).
    func testTheScannerStillFindsFileProducingWrappers() throws {
        let wrappers = try Self.fileProducingWrappers()

        XCTAssertGreaterThanOrEqual(wrappers.count, 5, """
            The scanner found \(wrappers.count) throwing functions in Sources that \
            write a file. It has found ten or more every time it has been run, so \
            this means the parser has stopped recognising declarations rather than \
            the tree having changed. While it reads zero, a `try?` on any wrapper \
            is invisible to this guard, which is exactly how #462's four sites \
            survived it.

            Found: \(wrappers.sorted().joined(separator: ", "))
            """)
    }

    private func matches(_ key: String, _ occurrence: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return occurrence.hasPrefix(parts[0] + "|") && occurrence.contains(parts[1])
    }
}
