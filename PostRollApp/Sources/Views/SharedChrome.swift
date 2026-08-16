import SwiftUI

/// Small chrome shared across screens, kept out of any one screen's file so
/// a view that uses them can be rendered without dragging that screen (and
/// its app state) along with it (#393).

// MARK: - Stage Back Button (reused across stages)

struct StageBackButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(PaintedSurfaces.secondaryText)
        }
        .buttonStyle(.plain)
    }
}

/// Why a control will not do what it looks like it does, drawn on screen.
///
/// One view rather than a copy per screen, because the whole defect this exists
/// to stop is a refusal that got computed and then had nowhere to go (#402).
///
/// Quiet on purpose: this sits under a control that is already visibly
/// unavailable, so it explains rather than alarms. What it must not be is
/// absent, or delivered only on hover, which is a refusal nobody finds (L49,
/// L109).
struct RefusalNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(message)
                .font(.light(10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PaintedSurfaces.refusalNoteText)
    }
}

struct BrandButtonStyle: ButtonStyle {

    /// The label colour and the fill behind it, named so a legibility check can
    /// read the same values this style draws with (#559).
    ///
    /// Every primary button in the app is this style, and a filled button's ink
    /// measurement is dominated by its own background: the words could be drawn
    /// in the fill colour and the page would still measure as full. So the pair
    /// is checked for contrast, and it is checked against THESE rather than
    /// against a copy of the two colours, which would only confirm itself (L70).
    static let label = Color.cream
    static let fill = Color.roseButton
    static let pressedFill = Color.roseDeep

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Self.label)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(configuration.isPressed ? Self.pressedFill : Self.fill)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .focusEffectDisabled()
    }
}

/// A control that is plainly a control without competing with the lead action.
///
/// Exists because a screen offering two real choices had one of them rendered
/// as bare text, which reads as a heading rather than something to press (#393).
struct BrandOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PaintedSurfaces.outlineButtonLabel)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.roseDeep.opacity(0.55), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .fill(configuration.isPressed
                                  ? Color.clear : PaintedSurfaces.outlineButtonHitArea))
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
