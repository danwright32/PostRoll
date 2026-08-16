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

            ForEach(FindingsDisplay.grouped(findings: findings), id: \.code) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(group.details, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
}
