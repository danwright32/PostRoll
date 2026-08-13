import Foundation

/// What is in a folder, or why that could not be answered (#451).
///
/// `(try? fm.contentsOfDirectory(...)) ?? []` reads as harmless and turns a
/// folder nobody is allowed to read into a folder with nothing in it. Four
/// places did it, and each produced a confidently wrong answer about something
/// different: an import that told Dan no photos were found and coached him
/// through renaming folders, a completion record that certified a day as
/// holding zero files, and a finished export reported as never finished with
/// advice to run it again.
///
/// An empty folder and an unreadable one need opposite responses, so they are
/// two answers rather than one (L10, L11), and the distinction is made once
/// rather than at each call site (L30).
enum DirectoryListing: Equatable {

    /// The folder was read. It may hold nothing, which is a real answer.
    case entries([URL])

    /// The folder could not be read at all, with the system's reason.
    case unreadable(String)

    /// Everything in `url`, hidden files skipped.
    static func of(_ url: URL, keys: [URLResourceKey] = [],
                   fileManager: FileManager = .default) -> DirectoryListing {
        do {
            let found = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            return .entries(found.sorted { $0.lastPathComponent < $1.lastPathComponent })
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// The entries, or none. For the callers that genuinely have somewhere else
    /// to report the failure and only need the list here.
    ///
    /// Deliberately named so a reader can see the answer is being flattened.
    /// The nameless `?? []` is what made this whole class invisible.
    var entriesIgnoringFailure: [URL] {
        switch self {
        case .entries(let found): return found
        case .unreadable:         return []
        }
    }

    var failureReason: String? {
        switch self {
        case .entries:                return nil
        case .unreadable(let reason): return reason
        }
    }
}
