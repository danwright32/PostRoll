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
