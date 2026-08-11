import Foundation

/// Pulls the @ handles out of the event's organization and venue fields so
/// they can be offered when tagging a photo. Those fields are free text, not
/// a bare handle: "@bludlineodyssey presented by @matchbookfestival" carries
/// two accounts inside a sentence, and treating the whole string as one tag
/// would put prose into the caption's credits.
enum EventHandleSuggestions {
    /// Instagram handles are letters, digits, periods and underscores. A
    /// trailing period is far more likely to end a sentence than a handle, so
    /// it is trimmed.
    private static let pattern = try? NSRegularExpression(pattern: "@[A-Za-z0-9._]+")

    static func tokens(from text: String) -> [String] {
        guard let pattern else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        var seen = Set<String>()
        for match in pattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            var token = String(text[r])
            while token.hasSuffix(".") { token.removeLast() }
            // isRealHandle rejects a bare "@" and the sentinels recorded when
            // no handle could be found, which must never reach a caption.
            guard PythonBridge.isRealHandle(token) else { continue }
            guard seen.insert(token.lowercased()).inserted else { continue }
            out.append(token)
        }
        return out
    }

    /// Every event-wide account, however the field happens to be written (#289).
    ///
    /// The field holds two different shapes in practice. The OCR review writes
    /// it as a comma separated list of bare names ("dciny, carnegiehall"), which
    /// is what all 19 events on disk carry; a person typing it may write a
    /// sentence with @ handles in it, which is what `tokens(from:)` is for.
    /// Reading only the second shape found nothing in any real event, so the
    /// accounts tagged on every post were invisible to everything downstream.
    ///
    /// A comma separated piece is only taken when it is a single word that
    /// could be a handle. Prose is left to the @ matcher, so "presented by the
    /// festival" cannot become an account.
    static func accounts(in field: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for piece in field.split(separator: ",", omittingEmptySubsequences: true) {
            let text = String(piece)
            var found = tokens(from: text)
            if found.isEmpty {
                let bare = CaptionBlocks.bareUsername(text)
                if !bare.isEmpty,
                   !bare.contains(where: \.isWhitespace),
                   PythonBridge.isRealHandle(bare) {
                    found = [bare]
                }
            }
            for token in found where seen.insert(token.lowercased()).inserted {
                out.append(token)
            }
        }
        return out
    }

    /// Every event-wide account, in the order they appear in the field.
    static func tokens(fromAll fields: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for field in fields {
            for token in tokens(from: field) where seen.insert(token.lowercased()).inserted {
                out.append(token)
            }
        }
        return out
    }
}
