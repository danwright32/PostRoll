import SwiftUI

/// The deterministic checks, under the text they describe.
///
/// One view for both features (#603). It was two, about 81% identical, one for
/// the caption's checks and one for the blog's, and the differences were not
/// decisions: the caption's panel collapsed into a single labelled group for
/// VoiceOver and the blog's did not, so the same panel was one stop on one
/// screen and a heap of unlabelled fragments on the other. The colour fix in
/// #600 had to be made twice for the same reason.
///
/// These checks REPORT rather than repair, which is why the quoted text is the
/// feature: nothing here knows the handle that should have been used in place
/// of a guessed one, and guessing a second time is the failure the check exists
/// to stop. Once the text is edited the findings no longer describe it, so the
/// panel says so rather than going on asserting them.
struct FindingsPanel: View {

    /// The heading, from `FindingsDisplay.summary`.
    let summary: String
    let findings: [QualityFinding]
    let isStale: Bool
    /// What the checks ran against, "caption" or "draft". It reaches the stale
    /// sentence and the spoken label, so both name the thing that was edited.
    let subject: String
    /// Take one finding off the panel, by `FindingsDisplay.key` (#958).
    ///
    /// Optional so a surface that cannot store a clearance does not draw a
    /// control that would do nothing when pressed, which is the dead control
    /// this exists to remove one level up (L109, L148).
    var onClear: ((String) -> Void)? = nil

    private var colours: (badge: Color, panel: Color, border: Color, ink: Color) {
        PaintedSurfaces.captionFindings(stale: isStale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: isStale ? "clock.arrow.circlepath"
                                          : "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(summary.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
            }
            .foregroundStyle(colours.ink)

            if isStale {
                Text(FindingsDisplay.staleNote(subject: subject))
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // `id: \.self` over the whole group, not `\.code` (#1132). Once
            // `grouped` keys on (code, repair), two groups can share a code,
            // and SwiftUI silently renders ONE of any pair sharing an id: rule
            // 2 defeated at the render step, one line past where the grouping
            // was fixed.
            ForEach(FindingsDisplay.grouped(findings: findings)) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if group.state != .never {
                            // The state gets its own icon as well as its own
                            // words. A colour difference alone is not a
                            // distinct state, and the words are what VoiceOver
                            // reads.
                            Image(systemName: group.state.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                        }
                        Text(group.message + group.state.headingSuffix)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.bodyText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if group.state != .never {
                        Text(group.state.note)
                            .font(.system(size: 10))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(group.details, id: \.self) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let onClear {
                                clearControls(code: group.code, detail: detail,
                                              message: group.message,
                                              onClear: onClear)
                            }
                        }
                        // Its own element, because the controls belong to THIS
                        // quote: a combined group would read as one stop with
                        // two buttons and no way to tell which finding they
                        // act on.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(group.message): \(detail)")
                    }
                    // A finding with no quoted text still has to be clearable,
                    // and its control belongs on the heading, which is all
                    // there is of it (#958).
                    if group.details.isEmpty, let onClear {
                        clearControls(code: group.code, detail: "",
                                      message: group.message, onClear: onClear)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    group.state == .never
                        ? group.message
                        : "\(group.message). \(group.state.note)")
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(colours.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .stroke(colours.border, lineWidth: 1.5)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FindingsDisplay.spokenLabel(subject: subject,
                                                        summary: summary))
    }

    /// The two ways one finding leaves the panel (#958).
    ///
    /// A tick and a cross, and they do the SAME thing: the finding goes, and
    /// nothing is recorded about which was pressed. Dan's call on 2026-08-29,
    /// shown the trade that asking why would let a noisy check type be counted
    /// as noisy. Both are here because they mean different things to the
    /// person pressing them, and neither is a prompt for a reason.
    ///
    /// Each names the finding it belongs to, so a panel with four of them is
    /// four distinct controls to a screen reader rather than four "Dismiss"s.
    @ViewBuilder
    private func clearControls(code: String, detail: String, message: String,
                               onClear: @escaping (String) -> Void) -> some View {
        let key = "\(code)|\(detail)"
        let named = detail.isEmpty ? message : detail
        HStack(spacing: 4) {
            Button { onClear(key) } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
            .buttonStyle(.plain)
            .help("I have handled this")
            .accessibilityLabel("Handled: \(named)")

            Button { onClear(key) } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss this check")
            .accessibilityLabel("Dismiss: \(named)")
        }
    }
}
