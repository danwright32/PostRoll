import XCTest

/// No image may cross an actor boundary (#461, found by the CI app build #521
/// added).
///
/// `NSImage` is not `Sendable`, so returning one from a detached task is an
/// error under strict concurrency. Nine loaders did exactly that, and nothing
/// noticed for as long as they existed: the local Xcode accepts what the CI one
/// rejects, and until #521 no CI job compiled the view layer at all.
///
/// A source scan rather than a behaviour test, because the failure is a compile
/// error on one toolchain and invisible on another, and the thing worth holding
/// is the shape: load the BYTES off the main thread and build the image here.
final class ImageActorBoundaryGuardTests: XCTestCase {

    private static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// `ImageLoad` is the one place allowed to do the loading, and it hands back
    /// `Data`.
    private static let allowedFile = "ImageLoad.swift"

    private static func swiftFiles() throws -> [URL] {
        var found: [URL] = []
        let files = FileManager.default.enumerator(at: sourcesDir,
                                                   includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found
    }

    func testTheScanCanSeeTheSourceTree() throws {
        // A scan that finds no files passes every assertion below while
        // checking nothing (L98).
        XCTAssertGreaterThan(try Self.swiftFiles().count, 20)
    }

    func testNoDetachedTaskHandsBackAnImage() throws {
        var offenders: [String] = []
        for url in try Self.swiftFiles() where url.lastPathComponent != Self.allowedFile {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // A comment ABOUT the pattern is not the pattern (L103).
                guard !line.hasPrefix("//"), !line.hasPrefix("///"), !line.hasPrefix("*") else { continue }
                guard line.contains("Task.detached") else { continue }
                // The image may be named on this line or on the next few, since
                // the closure is usually wrapped.
                let window = lines[i..<min(i + 5, lines.count)]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix("//") }
                    .joined(separator: " ")
                if window.contains("NSImage") {
                    offenders.append("\(url.lastPathComponent):\(i + 1)  \(line)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            A detached task hands back an NSImage, which is not Sendable, so this \
            does not compile on the Xcode CI runs even though the local one accepts it.

            Load the bytes off the main thread and build the image on this side: \
            `ImageLoad.read(url)` already does it.

            \(offenders.joined(separator: "\n"))
            """)
    }

    func testTheGuardActuallyFindsThisPattern() throws {
        // The scan is only worth anything if it matches the shape it forbids.
        let sample = """
            .task {
                image = await Task.detached {
                    NSImage(contentsOf: url)
                }.value
            }
            """
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        var matched = false
        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("Task.detached") else { continue }
            let window = lines[i..<min(i + 5, lines.count)]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            if window.contains("NSImage") { matched = true }
        }
        XCTAssertTrue(matched, "the scan does not match the pattern it forbids")
    }
}
