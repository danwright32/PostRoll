import Foundation

/// How the deterministic blog checks (#201) present on the review screen.
///
/// The checks REPORT rather than rewrite, because most of them cannot be
/// auto-fixed without inventing something: nobody can supply the true number
/// that replaces an invented one, and alt text cannot be rewritten without
/// seeing the photograph. So the whole value is in Dan seeing the quoted text.
///
/// A finding is measured against the body as GENERATED. The moment he edits
/// that body the finding may already be fixed, and a report that keeps
/// asserting itself after the correction is worse than none: it trains him to
/// ignore the panel. `isStale` is what stops it outliving the fix.
enum BlogFindingsDisplay {

    struct Group: Equatable {
        let code: String
        let message: String
        let details: [String]
    }

    /// True once the body no longer matches what the checks actually ran on.
    ///
    /// An empty `findingsBody` is not evidence of an edit: a blog saved before
    /// this field existed has no record of what was checked, and calling that
    /// stale would grey out every finding on every older event.
    static func isStale(blog: BlogOutput) -> Bool {
        !blog.findingsBody.isEmpty && blog.body != blog.findingsBody
    }

    /// Header line, or nil when there is nothing to show.
    static func summary(blog: BlogOutput) -> String? {
        let count = blog.findings.count
        guard count > 0 else { return nil }
        if isStale(blog: blog) {
            return "\(count) check\(count == 1 ? "" : "s") against the original draft"
        }
        return "\(count) check\(count == 1 ? "" : "s") to fix"
    }

    /// One heading per rule, in first-appearance order, with every offending
    /// quote under it. Seven over-long alt texts are one problem to work
    /// through, not seven separate alarms.
    static func grouped(findings: [BlogFinding]) -> [Group] {
        var order: [String] = []
        var messages: [String: String] = [:]
        var details: [String: [String]] = [:]

        for finding in findings {
            if messages[finding.code] == nil {
                order.append(finding.code)
                messages[finding.code] = finding.message
                details[finding.code] = []
            }
            if !finding.detail.isEmpty {
                details[finding.code]?.append(finding.detail)
            }
        }

        return order.map {
            Group(code: $0, message: messages[$0] ?? "", details: details[$0] ?? [])
        }
    }
}


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
