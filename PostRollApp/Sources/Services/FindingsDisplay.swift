import Foundation

/// How a deterministic check that REPORTS presents on the review screen.
///
/// Two features share this, and the shape is the same for both because the
/// reason for it is the same. The blog checks (#201) cannot auto-fix: nobody
/// can supply the true number that replaces an invented one, and alt text
/// cannot be rewritten without seeing the photograph. The caption credit
/// checks (#475) cannot either: nothing here knows the handle that should have
/// been used in place of a guessed one. In both cases the whole value is in
/// Dan seeing the quoted text.
///
/// A finding is measured against a specific piece of text. The moment he edits
/// that text the finding may already be fixed, and a report that keeps
/// asserting itself after the correction is worse than none: it trains him to
/// ignore the panel. `isStale` is what stops it outliving the fix.
///
/// One implementation rather than one per feature. The second copy is where
/// the two drift, and they drift silently: a caption panel that never went
/// stale would go on naming a handle Dan had already removed.
enum FindingsDisplay {

    struct Group: Equatable {
        let code: String
        let message: String
        let details: [String]
    }

    /// True once the text no longer matches what the checks actually ran on.
    ///
    /// An empty `checked` is not evidence of an edit: anything saved before the
    /// checked text was recorded has no record of what was measured, and
    /// calling that stale would grey out the findings on every older event.
    static func isStale(checked: String, current: String) -> Bool {
        !checked.isEmpty && current != checked
    }

    /// Header line, or nil when there is nothing to show.
    ///
    /// `subject` names what was checked ("draft", "caption") so the stale
    /// wording points at the thing Dan edited rather than at a generic noun.
    static func summary(count: Int, stale: Bool, subject: String) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "check" : "checks"
        if stale { return "\(count) \(noun) against the original \(subject)" }
        return "\(count) \(noun) to fix"
    }

    /// One heading per rule, in first-appearance order, with every offending
    /// quote under it. Seven over-long alt texts are one problem to work
    /// through, not seven separate alarms.
    static func grouped(findings: [QualityFinding]) -> [Group] {
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


extension BlogOutput {
    /// True once Dan has edited the body the checks were measured against.
    var findingsAreStale: Bool {
        FindingsDisplay.isStale(checked: findingsBody, current: body)
    }

    var findingsSummary: String? {
        FindingsDisplay.summary(count: findings.count, stale: findingsAreStale,
                                subject: "draft")
    }
}


extension DayCaption {
    /// True once Dan has edited the caption the checks were measured against.
    var findingsAreStale: Bool {
        FindingsDisplay.isStale(checked: findingsCaption, current: caption)
    }

    var findingsSummary: String? {
        FindingsDisplay.summary(count: findings.count, stale: findingsAreStale,
                                subject: "caption")
    }
}
