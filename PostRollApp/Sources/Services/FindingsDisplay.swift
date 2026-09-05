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

    struct Group: Equatable, Hashable, Identifiable {
        let code: String
        /// What the repair pass did about the findings under this heading
        /// (#1132). Part of the key, not decoration: a tried finding and a
        /// never-attempted finding of the SAME code are two different things
        /// to tell Dan, and merging them under one heading is rule 2 defeated.
        let repair: String
        let message: String
        let details: [String]

        /// Composite, because `code` alone is no longer unique and SwiftUI
        /// silently renders ONE of any pair sharing an id. That is the render
        /// step one line past where the grouping was fixed.
        var id: String { "\(code)|\(repair)" }

        var state: RepairState { RepairState(raw: repair) }
    }

    /// What a cleared finding is remembered by (#958).
    ///
    /// The code and the quoted text, because that pair is what Dan judged: the
    /// same rule against a different quote is a different finding, and the
    /// position in the list is not a key at all, since one fix reorders the
    /// rest.
    ///
    /// It deliberately does NOT survive a regeneration, and nothing here has to
    /// remember that: `applyFindings` drops every clearance when it attaches a
    /// fresh set, so a regenerated caption is judged again from nothing (L15).
    static func key(for finding: QualityFinding) -> String {
        "\(finding.code)|\(finding.detail)"
    }

    /// The findings still worth showing: everything Dan has not cleared.
    ///
    /// Filtered here rather than deleted from the stored list, so the record of
    /// what the checks found survives a clearance and the panel is the only
    /// thing that changes (L116: a preference filters what is shown, it does
    /// not delete the data behind it).
    static func remaining(findings: [QualityFinding],
                          cleared: [String]) -> [QualityFinding] {
        guard !cleared.isEmpty else { return findings }
        let gone = Set(cleared)
        return findings.filter { !gone.contains(key(for: $0)) }
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

    /// What the panel says once the text has moved on under it (#603).
    ///
    /// Beside `summary` because it is the same decision: the sentence names
    /// what the checks ran against, so it points at the thing Dan edited. It
    /// was written out twice in the view, once per feature, with the same two
    /// verbs in a different order, which is one sentence written twice.
    static func staleNote(subject: String) -> String {
        "These ran against the \(subject) as generated. You have edited it since, "
        + "so some may already be fixed. Revise or regenerate to re-check."
    }

    /// What a person hears instead of the panel's contents, naming which checks
    /// these are. The caption's panel had one and the blog's had none.
    static func spokenLabel(subject: String, summary: String) -> String {
        "\(subject.prefix(1).uppercased())\(subject.dropFirst()) checks: \(summary)"
    }

    /// One heading per rule, in first-appearance order, with every offending
    /// quote under it. Seven over-long alt texts are one problem to work
    /// through, not seven separate alarms.
    /// The markers a retry would name, in the order they appear (#1160).
    ///
    /// De-duplicated, because a marker routinely breaks three rules at once and
    /// the retry is a pass over MARKERS: naming one three times would pay for
    /// it three times.
    ///
    /// A finding with no target names nothing. `stacked_photos` and the prose
    /// rules carry none, and sending an empty string would ask Python to
    /// repair a marker that is not in the post.
    ///
    /// An empty result is what the control reads to decide whether to appear
    /// at all: a retry offered when nothing can be retried is the same dead
    /// control pointing the other way.
    static func retryableTargets(findings: [QualityFinding]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for finding in findings where finding.repairState.invitesRetry {
            let target = finding.target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !seen.contains(target) else { continue }
            seen.insert(target)
            out.append(target)
        }
        return out
    }

    static func grouped(findings: [QualityFinding]) -> [Group] {
        // Keyed on (code, repair) rather than code alone (#1132). Without the
        // repair state in the key, a rule the app TRIED and failed to fix and
        // the same rule it never attempted merge under one heading, and Dan is
        // told nothing about which is which.
        struct Key: Hashable { let code: String; let repair: String }

        var order: [Key] = []
        var messages: [Key: String] = [:]
        var details: [Key: [String]] = [:]

        for finding in findings {
            let key = Key(code: finding.code, repair: finding.repair)
            if messages[key] == nil {
                order.append(key)
                messages[key] = finding.message
                details[key] = []
            }
            if !finding.detail.isEmpty {
                details[key]?.append(finding.detail)
            }
        }

        return order.map {
            Group(code: $0.code, repair: $0.repair,
                  message: messages[$0] ?? "", details: details[$0] ?? [])
        }
    }
}


extension BlogOutput {
    /// True once Dan has edited the body the checks were measured against.
    var findingsAreStale: Bool {
        FindingsDisplay.isStale(checked: findingsBody, current: body)
    }

    /// The findings still on the panel: what the checks found, less what Dan
    /// has cleared (#958).
    var openFindings: [QualityFinding] {
        FindingsDisplay.remaining(findings: findings, cleared: clearedFindings)
    }

    var findingsSummary: String? {
        FindingsDisplay.summary(count: openFindings.count, stale: findingsAreStale,
                                subject: "draft")
    }
}


extension DayCaption {
    /// True once Dan has edited the caption the checks were measured against.
    var findingsAreStale: Bool {
        FindingsDisplay.isStale(checked: findingsCaption, current: caption)
    }

    /// The findings still on the panel: what the checks found, less what Dan
    /// has cleared (#958).
    var openFindings: [QualityFinding] {
        FindingsDisplay.remaining(findings: findings, cleared: clearedFindings)
    }

    var findingsSummary: String? {
        FindingsDisplay.summary(count: openFindings.count, stale: findingsAreStale,
                                subject: "caption")
    }
}
