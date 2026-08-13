import Foundation

/// Put a file somewhere without destroying what is already there (#445).
///
/// The shape this exists to stop: delete the destination, then write. A failure
/// between the two has already destroyed the file the person had, and the thing
/// that was supposed to replace it does not exist (L5). The program PDF
/// download did exactly that to a destination Dan chose himself in a save
/// panel, which could be any file on his disk.
///
/// So: write beside the destination first, then swap. `replaceItemAt` is atomic
/// and keeps the original until the new one is in place, and the temp file is
/// created in the destination's own directory so the swap never crosses a
/// volume boundary.
///
/// One implementation rather than three. `ProgramPDFBuilder` and
/// `PreviewMergePolicy` had already worked this out separately, which is two
/// chances for the third caller to get it wrong, and it did.
enum SafeFileSwap {

    /// Writes `data` at `destination`, leaving whatever is there untouched
    /// unless the whole write succeeds.
    static func install(_ data: Data, at destination: URL) throws {
        try install(at: destination) { temp in
            try data.write(to: temp, options: .atomic)
        }
    }

    /// Copies `source` to `destination`, leaving whatever is there untouched
    /// unless the whole copy succeeds.
    ///
    /// The copy goes through the temp file rather than straight to the
    /// destination, so a source that vanishes or a disk that fills part way
    /// costs the copy and not the file already at the destination.
    static func install(copyOf source: URL, at destination: URL) throws {
        try install(at: destination) { temp in
            try FileManager.default.copyItem(at: source, to: temp)
        }
    }

    /// The swap itself: build the new file at a temporary path beside the
    /// destination, then put it in place.
    private static func install(at destination: URL,
                                producing: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let temp = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).part")
        // Runs whichever way this ends. On success the temp has been moved and
        // there is nothing left to remove; on failure it is the half-written
        // file that must not be left lying beside the real one.
        defer { try? fm.removeItem(at: temp) }

        try producing(temp)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }
}
