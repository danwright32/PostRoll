import Foundation

/// What Dan copies when he takes the blog post out of PostRoll (#205).
///
/// The title is generated deterministically, stored on the output, shown in
/// the review header and written as the heading on export, and he still had to
/// type it by hand on both recent posts, because the surface he actually
/// drafts and copies from carries the body alone.
///
/// The title is joined at copy time rather than pushed into the body text: the
/// body goes through the review passes and the deterministic checks, and a
/// heading living inside it would be one more thing those rules have to know
/// about.
enum BlogDraftText {

    /// `body` with each photo marker's FILENAME swapped for its exported name.
    ///
    /// The export writes the blog photographs out renumbered as `photo_01.jpg`
    /// and so on, and wrote `draft.md` from the body unchanged, so every
    /// marker in the exported draft named a file that is not in the export and
    /// every file in the export was named by nothing (#1142). The export
    /// folder is the deliverable: it is what gets uploaded.
    ///
    /// Only the filename. The alt text is what a screen reader announces and
    /// is judged against the photograph, so it is an export detail in no
    /// sense. Prose is untouched too, including prose that happens to contain
    /// a filename: the writing is Dan's and the export is not entitled to edit
    /// it, which is why this matches the MARKER rather than the name.
    ///
    /// A marker with no entry in `names` is left exactly as it is rather than
    /// renamed to a guess. One naming a photograph that is not in the export
    /// is a fault the blog checks already report, and inventing a name for it
    /// would hide that (L98).
    static func renamingPhotos(in body: String,
                               to names: [String: String]) -> String {
        guard !names.isEmpty else { return body }
        // The marker's own shape, matching Python's `_PHOTO_MARKER`: a
        // filename up to the pipe, then the alt text up to the close. The
        // filename may hold spaces, quotes, brackets and an at sign, because
        // Dan's carry the show title, the venue and his handle.
        let pattern = #"\[PHOTO:\s*([^|\]]+?)\s*\|"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return body }

        let text = body as NSString
        var out = ""
        var at = 0
        for match in re.matches(in: body, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            out += text.substring(with: NSRange(location: at,
                                                length: match.range.location - at))
            if let exported = names[name] {
                out += "[PHOTO: \(exported) |"
            } else {
                out += text.substring(with: match.range)
            }
            at = match.range.location + match.range.length
        }
        out += text.substring(from: at)
        return out
    }

    /// Markdown heading plus body, ready to paste.
    static func copyText(title: String, body: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return text }
        guard !text.isEmpty else { return "# \(name)" }
        // Not added twice: a body that already opens with the heading is left
        // as it is, so copying a post that was pasted back in stays clean.
        if text.hasPrefix("# \(name)") { return text }
        return "# \(name)\n\n\(text)"
    }
}
