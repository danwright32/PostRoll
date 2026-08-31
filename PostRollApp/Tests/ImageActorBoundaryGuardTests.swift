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

    /// `ImageLoad` is the one place allowed to do the loading.
    private static let allowedFile = "ImageLoad.swift"

    /// The image types that must not come back out of a detached task.
    ///
    /// `CGImage` joined `NSImage` with #966, which is when carrying a decoded
    /// image across a boundary became a thing anybody would try: before that
    /// the only image type in reach was `NSImage`. Neither is Sendable, and
    /// `CGImage`'s crossing is the more tempting of the two because under
    /// `targeted` concurrency it is a warning rather than an error, so it
    /// compiles on both toolchains and reads as fine. The one deliberate
    /// crossing is `ImageLoad.DecodedImage`, which is a box that says in
    /// writing why it is safe; a bare one is not.
    private static let imageTypes = ["NSImage", "CGImage"]

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
                // Only what is INSIDE the closure. Stopping at its end matters:
                // building an image from bytes on this side, one line after an
                // unrelated detached task, is the shape being asked for, and a
                // guard that flags it is a guard nobody can satisfy.
                let body = Self.detachedBody(lines, from: i)
                if Self.imageTypes.contains(where: body.contains) {
                    offenders.append("\(url.lastPathComponent):\(i + 1)  \(line)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            A detached task hands back an image type, which is not Sendable. For \
            NSImage that does not compile on the Xcode CI runs even though the local \
            one accepts it; for CGImage it is a warning under targeted concurrency, \
            so it compiles on both and reads as fine.

            Go through `ImageLoad.read(url, fitting:)`, which crosses the boundary in \
            a box that says why that one is safe.

            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The closure a `Task.detached` on `line` opens, up to and including the
    /// line that closes it.
    private static func detachedBody(_ lines: [Substring], from line: Int) -> String {
        var body: [String] = []
        for raw in lines[line..<min(line + 8, lines.count)] {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if !text.hasPrefix("//") { body.append(text) }
            if text.contains("}.value") || text.hasSuffix("}.value") { break }
        }
        return body.joined(separator: " ")
    }

    func testTheGuardActuallyFindsThisPattern() throws {
        // The scan is only worth anything if it matches the shape it forbids.
        // Every type it names, not just the first: a list checked through one
        // of its entries says nothing about the others (L178).
        for type in Self.imageTypes {
            let sample = """
                .task {
                    image = await Task.detached {
                        \(type)(contentsOf: url)
                    }.value
                }
                """
            let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
            var matched = false
            for (i, rawLine) in lines.enumerated()
            where rawLine.trimmingCharacters(in: .whitespaces).contains("Task.detached") {
                let body = Self.detachedBody(lines, from: i)
                if Self.imageTypes.contains(where: body.contains) { matched = true }
            }
            XCTAssertTrue(matched, "the scan does not match \(type), which it forbids")
        }
    }

    func testTheGuardDoesNotFlagBuildingAnImageFromBytesAfterwards() throws {
        // The shape this whole change is moving TO: an unrelated detached task,
        // then the image built from Sendable bytes on this side.
        let sample = """
            async let bytes = ImageLoad.bytes(url)
            async let decoded = Task.detached {
                LayoutSidecar.read(at: layoutURL).cells
            }.value
            let (loadedBytes, cells) = await (bytes, decoded)
            let loadedImage = loadedBytes.flatMap { NSImage(data: $0) }
            """
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, rawLine) in lines.enumerated()
        where rawLine.trimmingCharacters(in: .whitespaces).contains("Task.detached") {
            let body = Self.detachedBody(lines, from: i)
            XCTAssertFalse(Self.imageTypes.contains(where: body.contains),
                           "the scan flags an image built outside the detached closure")
        }
    }
}
