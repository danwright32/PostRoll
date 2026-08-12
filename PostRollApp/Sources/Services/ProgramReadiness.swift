import Foundation

/// Whether the stored program is still whole at the moment OCR is about to
/// read it.
///
/// Separate from the import side, and separate from what an accepted shortfall
/// records, because it answers a different question at a different time: the
/// import decides what may be stored, this decides whether what IS stored can
/// still be read (#387).
///
/// A page can be deleted, moved, or reclaimed at any point after it was
/// imported, and OCR reads whatever paths the event holds now. A page that is
/// gone reads as a program that never had it (#372), and an empty list used to
/// bounce Dan back to the upload screen with nothing saying why (#374).
enum ProgramReadiness: Equatable {
    case ready
    /// The event holds no program pages at all.
    case noPages
    /// Pages the event still points at that cannot be read.
    case missingFiles([URL])

    /// Why OCR will not run, or nil when it will. Nil rather than an empty
    /// string so a caller cannot render a blank refusal over a good program.
    var refusal: String? {
        switch self {
        case .ready:
            return nil
        case .noPages:
            return "There are no program pages to read yet. Add the program above, "
                + "or choose \"No program\" if this shoot doesn't have one."
        case .missingFiles(let urls):
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            let count = urls.count
            // "Cannot be read", not "was deleted": the check underneath only
            // asks whether the file can be seen, and on a Mac a file the app
            // is blocked from reading is indistinguishable from one that is
            // gone. A message may claim only what its check measured.
            return "\(count) program page\(count == 1 ? "" : "s") can't be read "
                + "(\(names)). \(count == 1 ? "It" : "They") may have been moved, deleted, "
                + "or blocked by macOS privacy settings. Reading the rest would treat what "
                + "is left as the whole program, so add \(count == 1 ? "it" : "them") again "
                + "before running OCR."
        }
    }

    /// Checks every page the event points at can actually yield its content.
    ///
    /// Readability, not mere existence: a zero byte or unreadable file passes
    /// an existence check, reaches OCR, and contributes nothing, which is the
    /// same quietly short program by another route. The refusal this produces
    /// says the page cannot be read, so this is what has to be measured (#379).
    static func of(_ pages: [URL], fileManager: FileManager = .default) -> ProgramReadiness {
        guard !pages.isEmpty else { return .noPages }
        let unreadable = pages.filter { !isReadable($0, fileManager: fileManager) }
        return unreadable.isEmpty ? .ready : .missingFiles(unreadable)
    }

    /// Whether one page yields at least one byte.
    ///
    /// Opens the file and reads a byte rather than reading it whole: a program
    /// page is a multi megabyte scan, and this runs for every page each time
    /// Run OCR is pressed. One byte is enough to separate a file that is there
    /// and readable from one that is absent, empty, or blocked, which is
    /// exactly what the refusal claims.
    private static func isReadable(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = try? handle.read(upToCount: 1)
        return (head?.isEmpty == false)
    }
}
