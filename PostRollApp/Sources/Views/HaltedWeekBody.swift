import SwiftUI

// MARK: - How prominent a control is allowed to be
//
// The three tiers this app uses, written down here because #395 styled one paid
// action as an outlined control and left another as body-coloured text, and
// nothing recorded whether that was a decision or an oversight (#398).
//
//   Filled (`BrandButtonStyle`)         The decision on the screen. Exactly one.
//   Outlined (`BrandOutlineButtonStyle`) A real alternative to that decision,
//                                        standing on its own with no filled
//                                        button beside it to be read against.
//   Accent text (`.plain` + roseGold)   A side route: useful, not the decision,
//                                        and read correctly as a link because
//                                        it is not the colour of prose.
//
// Two rules cut across those tiers, and both are enforced in
// VisibleControlGuardTests rather than left to review:
//
//   1. An action that IS the decision is never body-coloured text. A bare-text
//      option reads as a heading above its own explanation, which is how the
//      free way out of a halt shipped looking like a label (#395).
//   2. An action that SPENDS MONEY is never body-coloured text either, whatever
//      tier it sits in. It may be quiet; it may not be invisible. `Regenerate
//      All…` on caption review and `Regenerate blog post` on the generation done
//      screen are quiet on purpose, because each sits opposite a filled primary
//      that is the actual decision, so they take the accent rather than an
//      outline. `Re-cut with AI` stands alone with nothing to be quiet against,
//      which is why it took the outline instead.
//
// So the two paid actions in #398 do NOT look alike, and that is the answer
// rather than an accident: what they share is being legible controls, and what
// separates them is whether a filled primary is on screen to be quieter than.

/// How prominent each way out of a halt is.
///
/// Its own type so the rule can be read and tested, rather than living as an
/// if-else inside the layout. Both options are controls: an option rendered as
/// bare text is not offered at all, however clickable it happens to be (#393).
///
/// The free option leads. The paid one is still plainly a control, just not the
/// one the eye lands on, because the screen is met after a shoot when the
/// obvious button is the one that gets pressed.
enum HaltChoiceEmphasis: Equatable {
    /// Filled. Exactly one per screen.
    case primary
    /// Outlined. A control, and visibly not the lead.
    case secondary

    static func of(_ choice: HaltedWeek.Choice) -> HaltChoiceEmphasis {
        choice.spendsMoney ? .secondary : .primary
    }
}

/// What the halt screen shows below its header.
///
/// Its own view taking a `HaltedWeek` and a closure rather than reaching into
/// the generation screen's state, so it can be rendered and measured outside
/// the running app (#393). This is the screen Dan meets when a week stops at
/// the usage limit, which makes it a bad one to have never looked at.
struct HaltedWeekBody: View {
    let halted: HaltedWeek
    var onChoose: (HaltedWeek.Choice) -> Void = { _ in }

    /// What survived, said plainly. Without this the screen reads as a total
    /// loss and Dan re-runs work he already has.
    var survivedText: String {
        halted.finishedDays.isEmpty
            ? "The run stopped before any day finished, so there is nothing to keep yet."
            : "Finished and saved: "
              + halted.finishedDays.map { $0.rawValue.capitalized }.joined(separator: ", ") + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            BrandBanner(icon: "hourglass", message: halted.reason, style: .warning)
                .padding(.horizontal, Spacing.xl)

            Text(survivedText)
                .font(.system(size: 13))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .padding(.horizontal, Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(halted.choices, id: \.self) { choice in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        // Both are controls, and the free one leads. See
                        // HaltChoiceEmphasis for why.
                        switch HaltChoiceEmphasis.of(choice) {
                        case .primary:
                            Button(choice.label) { onChoose(choice) }
                                .buttonStyle(BrandButtonStyle())
                        case .secondary:
                            Button(choice.label) { onChoose(choice) }
                                .buttonStyle(BrandOutlineButtonStyle())
                        }
                        Text(choice.explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            // Without this the first explanation truncates to
                            // one line with an ellipsis while the second wraps,
                            // so the reason for the free option is the part
                            // that goes missing (#393).
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
    }
}
