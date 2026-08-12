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

    /// Every `try?` in Sources sitting on a file-producing call, as
    /// `file|trimmed line`.
    private static func discardedProducingWrites() throws -> [String] {
        var found: [String] = []
        let files = FileManager.default.enumerator(at: sourcesDir,
                                                   includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // A comment ABOUT the pattern is not the pattern. A guard that
                // matches prose is indistinguishable from one that works (L103).
                guard !line.hasPrefix("//"), !line.hasPrefix("///"), !line.hasPrefix("*") else { continue }
                guard line.contains("try?") else { continue }
                guard producingCalls.contains(where: { line.contains($0) }) else { continue }
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

    private func matches(_ key: String, _ occurrence: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return occurrence.hasPrefix(parts[0] + "|") && occurrence.contains(parts[1])
    }
}
