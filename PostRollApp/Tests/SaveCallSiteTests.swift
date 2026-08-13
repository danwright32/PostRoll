import XCTest

/// Every save goes through one method, so a failure cannot be dropped by one
/// call site while the others report it (#446).
///
/// Six call sites wrote the store directly and all six discarded the outcome.
/// Fixing five of them would have left the sixth silently losing work, and
/// nothing about reading any single one of them would have shown which.
final class SaveCallSiteTests: XCTestCase {

    func testNoScreenOrStatePathWritesTheStoreWithoutReportingIt() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "EventStore.swift",
                  url.lastPathComponent != "AppState.swift" else { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") }
                .joined(separator: "\n")
            if code.contains("EventStore.save(") {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These write the event store directly, so whether a failure is reported \
            depends on which one ran. Route the save through AppState:

            \(offenders.joined(separator: "\n"))
            """)
    }

    func testAppStateItselfKeepsTheSaveInOnePlace() throws {
        let appState = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppState.swift")
        let code = try String(contentsOf: appState, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")

        // Two: the one inside `persist`, and the one the debounced writer hands
        // its coalesced value to. Any more means an edit path that saves without
        // recording what happened.
        let writes = code.components(separatedBy: "EventStore.save(").count - 1

        XCTAssertEqual(writes, 2, """
            AppState writes the store in \(writes) places. Every edit has to go \
            through the one that records the outcome, or a failure is reported for \
            some edits and swallowed for others.
            """)
    }
}
