import Foundation

/// Joining a reason we did not write into prose we did.
///
/// Found by rendering the generation and OCR screens for the first time (#396).
/// Both of them interpolate a reason from somewhere else into the middle of a
/// sentence, and neither could know how that reason was punctuated, so the same
/// pattern shipped both failures at once:
///
///   "...couldn't be built: The page scans could not be read.. The page scans
///    have been kept."          <- an OS error already ended in a full stop
///   "Auto-flagging didn't run: connection reset by peer The data was
///    extracted..."             <- a library error ended in nothing at all
///
/// Neither is visible to a reader of either file, because the punctuation lives
/// in the value rather than in the line. So it is decided in one place instead.
enum Sentence {

    /// The reason, ending in exactly one sentence terminator, so prose can follow
    /// it without a gap or a stutter.
    ///
    /// Whitespace is trimmed at both ends first: a trailing newline or space puts
    /// the terminator in the wrong place and reads as a typo.
    static func closed(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // An ellipsis is already an ending, and a deliberate one. Left exactly as
        // it came, because collapsing it to a full stop rewrites the other
        // system's words, and adding a stop after it produces "…." which is what
        // a truncated stderr preview was doing on every long traceback (#405).
        if trimmed.hasSuffix("…") || trimmed.hasSuffix("...") { return trimmed }

        // Drop every terminator already there, then add exactly one back. A
        // reason ending "read.." or "wrong!?" is not something to reproduce.
        var body = Substring(trimmed)
        while let last = body.last, terminators.contains(last) {
            body = body.dropLast()
        }
        guard !body.isEmpty else { return trimmed }

        // Keep the reason's own choice of mark when it made one, so a question
        // does not become a statement.
        let mark = trimmed.last.flatMap { terminators.contains($0) ? $0 : nil } ?? "."
        return body + String(mark)
    }

    private static let terminators: Set<Character> = [".", "!", "?"]
}
