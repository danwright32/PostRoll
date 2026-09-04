import Foundation

/// Which of a day's preview files are actually on disk (#1117).
///
/// A VALUE the view holds, rather than a question it asks on every redraw.
///
/// `ReviewMediaStrip` and `CaptionSection` each decided what to show by calling
/// `FileManager.fileExists` from inside a computed property read by `body`, so
/// the answer was re-derived from the filesystem every time SwiftUI redrew the
/// row, once per candidate key. A `stat` is cheap next to the JPEG decodes #966
/// removed, which is why this is the remainder rather than the freeze, but it is
/// still file IO on the main thread for an answer that changes only when the day
/// is regenerated.
///
/// The same file already held the shape: `staleTemplates` is `@State`, read on
/// appear, "because it lists a directory and `body` runs on every redraw".
///
/// ## Why a type rather than a set of strings
///
/// The two screens ask the same question with different candidate lists, and a
/// bare `Set<String>` at each would be two places to remember to refresh. This
/// carries the answer and the emptiness together, so a view that has not
/// refreshed yet shows nothing rather than showing a stale yes.
struct PresentPreviewFiles: Equatable {

    /// The keys whose file was on disk when this was taken.
    private let present: Set<String>

    /// Nothing known yet, which is what a view holds before its first refresh.
    ///
    /// Answering NO for everything is the right starting state: a preview that
    /// appears a moment late is a redraw, and one that appears and then vanishes
    /// because the file was never there is a broken image (L10).
    static let none = PresentPreviewFiles(present: [])

    private init(present: Set<String>) { self.present = present }

    /// Take the reading.
    ///
    /// `exists` is a parameter so a test can drive this without touching a disk,
    /// and defaults to the real one so no call site can accidentally get a fake
    /// (L196).
    static func of(_ paths: [String: String]?,
                   exists: (String) -> Bool = {
                       FileManager.default.fileExists(atPath: $0)
                   }) -> PresentPreviewFiles {
        guard let paths else { return .none }
        return PresentPreviewFiles(
            present: Set(paths.compactMap { key, path in
                exists(path) ? key : nil
            }))
    }

    /// Whether this key's file was there.
    func has(_ key: String) -> Bool { present.contains(key) }

    /// The first of `keys` that is there, with whatever was paired with it.
    ///
    /// Order preserved, because these lists are PRIORITIES: the caller means
    /// "the best one available", and a set has no order to inherit (L343).
    func firstPresent<T>(of keys: [(String, T)]) -> (key: String, value: T)? {
        for (key, value) in keys where present.contains(key) {
            return (key, value)
        }
        return nil
    }

    /// Whether anything was found. Its own question, so a caller can tell "not
    /// refreshed yet" from "refreshed and this day has nothing".
    var isEmpty: Bool { present.isEmpty }
}
