import SwiftUI

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
                .foregroundStyle(Color.warmMid)
                .padding(.horizontal, Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(halted.choices, id: \.self) { choice in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        // The paid route carries the emphasised style so the
                        // two are not offered as if equivalent. Spending money
                        // should look like the deliberate one.
                        if choice.spendsMoney {
                            Button(choice.label) { onChoose(choice) }
                                .buttonStyle(BrandButtonStyle())
                        } else {
                            Button(choice.label) { onChoose(choice) }
                                .buttonStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.warmMid)
                        }
                        Text(choice.explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warmMid)
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
    }
}
