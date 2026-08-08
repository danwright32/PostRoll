import Foundation

/// Stepping through a day's photos in the tagging sheet. Clamps at both ends
/// rather than wrapping: reaching the last photo and being silently returned
/// to the first reads as a bug, and hides that the carousel has been walked.
enum PhotoTagSheetNavigation {
    static func clamped(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    static func canGoNext(from index: Int, count: Int) -> Bool {
        count > 0 && index < count - 1
    }

    static func canGoPrevious(from index: Int, count: Int) -> Bool {
        count > 0 && index > 0
    }

    static func next(from index: Int, count: Int) -> Int {
        canGoNext(from: index, count: count) ? index + 1 : clamped(index: index, count: count)
    }

    static func previous(from index: Int, count: Int) -> Int {
        canGoPrevious(from: index, count: count) ? index - 1 : clamped(index: index, count: count)
    }

    static func label(index: Int, count: Int) -> String {
        "Photo \(clamped(index: index, count: count) + 1) of \(count)"
    }
}
