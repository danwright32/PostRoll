import Foundation

/// What a knowingly incomplete program records, and when that record stops
/// being true.
///
/// Its own home because it is the only part of the program story that OUTLIVES
/// the import: the pages and the readiness check both describe a moment, while
/// this is written to the event and read hours later on the review screen
/// (#387).
///
/// Taking the readable pages of a damaged program is the one route by which a
/// short program legitimately becomes the program, which makes it the one place
/// the shortfall would otherwise vanish (#378).
enum ProgramShortfall {

    /// What to record when Dan takes the readable pages of a program that did
    /// not come in whole.
    ///
    /// Everything downstream reads the pages and cannot tell a program that is
    /// short from one that is small, and here it genuinely is short.
    static func acceptanceNote(for incomplete: ProgramImport.Incomplete) -> String {
        let taken = incomplete.pagesThatWorked.count
        let outOf = incomplete.declaredPageCount.map { " of \($0)" } ?? ""
        let causes = incomplete.failures.map(\.message).joined(separator: " ")
        return "\(incomplete.fileName): \(taken)\(outOf) pages were read. \(causes) "
            + "You chose to continue without the rest, so anything printed on "
            + "\(taken == 1 ? "the other pages" : "the missing pages") is not in the program data below."
    }

    /// The notes still true after a fresh import: a file that has since come in
    /// whole is no longer partial, so its note goes. A re-import that failed
    /// the same way leaves the program just as short, so its note stays.
    static func notes(_ existing: [String: String],
                      clearedBy plan: ProgramImport.Plan) -> [String: String] {
        var kept = existing
        for file in plan.imported { kept.removeValue(forKey: file.fileName) }
        return kept
    }
}
