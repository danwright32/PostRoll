import SwiftUI

/// The notice saying the numbers on screen were produced by the old timezone
/// reading (#549).
///
/// Its own view rather than inline in `InsightsOverviewView` (#559), so it can
/// be rendered and measured like every other notice this app shows. The screen
/// it sits on needs an AnalyticsStore, a HashtagStore and an AppState to build
/// at all, so a notice buried inside it can only ever be checked by scanning
/// the source for the rule it calls. That proves the call site exists; it
/// cannot notice a notice drawn off screen, at zero height, or in the colour
/// behind it, which is the failure this project has shipped three times.
///
/// It takes no arguments. The sentence is `AnalyticsStaleness.notice`, so a
/// rewording moves what is measured rather than leaving the test asserting a
/// copy that has drifted (L16).
struct AnalyticsStalenessNotice: View {

    /// The colours this notice draws with, named so a legibility check can read
    /// the same values the view uses (#559).
    ///
    /// Not decoration. Measuring ink on this notice cannot tell whether its
    /// WORDS are readable: the panel and its border put ink on the page whatever
    /// the type does, so the sentence could be drawn in the colour of the panel
    /// and the measurement would barely move. That was proved by breaking it and
    /// watching the check stay green. The contrast between these two is the part
    /// that says the sentence can be read, and a check that read its own
    /// constants instead of these would only ever confirm itself (L70).
    static let text = Color.warmDark
    static let icon = Color.roseDeep
    static let panel = Color.creamDeep
    static let border = Color.roseGold

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 12))
                .foregroundStyle(Self.icon)
            Text(AnalyticsStaleness.notice)
                .font(.light(12))
                .foregroundStyle(Self.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Self.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(Self.border, lineWidth: 1)
                )
        )
    }
}
