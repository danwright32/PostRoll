import SwiftUI

/// `CaseIterable` on purpose: the legibility check walks every case, so a
/// fourth style cannot be added without its colours being read against what is
/// behind them (#574).
enum BrandBannerStyle: CaseIterable {
    case info     // instructional — roseGold border, subtle bg
    case warning  // action needed — heavier roseGold border
    case error    // something wrong — roseDeep border
}

/// One escape-hatch action rendered as a button below a BrandBanner's
/// message (e.g. the Friday "< 3 usable clips" banner's "Import more
/// clips" / "Skip clips, keep story-only" pair, #135).
struct BrandBannerAction: Identifiable {
    let id = UUID()
    let label: String
    let action: () -> Void
}

struct BrandBanner: View {
    let icon: String
    let message: String
    var style: BrandBannerStyle = .info
    /// Optional action buttons shown below the message. Empty by default so
    /// every existing call site is unaffected.
    var actions: [BrandBannerAction] = []

    /// The colours this banner draws with, named so a legibility check can read
    /// the same values the view uses rather than a copy of them (L70, #574).
    ///
    /// Most of what this app tells Dan goes through this one view, and ink on
    /// the page cannot say whether any of it is readable: the fill and the left
    /// border are marks whatever the words do. So the message, the icon and the
    /// action buttons are each held against `background(_:)`, which is the fill
    /// as it actually lands rather than as it is declared.
    static let text = Color.warmMid

    /// Deeper than the `roseGold` these used to be. On the three banner fills
    /// that measured 3.83:1 to 3.97:1, under the 4.5:1 an 11pt label needs, and
    /// the ink check could not see it because the fill is most of what it reads.
    /// `roseDeep` puts the same buttons at 5.88:1 to 6.10:1. This is the remedy
    /// #569 used on the primary button, for the same reason (#574).
    static let actionLabel = Color.roseDeep

    static func fill(_ style: BrandBannerStyle) -> Color {
        switch style {
        case .info:    return Color.roseGold.opacity(0.07)
        case .warning: return Color.roseGold.opacity(0.10)
        case .error:   return Color.roseDeep.opacity(0.08)
        }
    }

    /// The colour actually behind the words: the translucent fill composited
    /// over the page. Judging a sentence against `fill(_:)` itself would
    /// compute a ratio against a colour that is never drawn.
    static func background(_ style: BrandBannerStyle) -> Color {
        fill(style).composited(over: PaintedSurfaces.page)
    }

    static func icon(_ style: BrandBannerStyle) -> Color {
        switch style {
        case .info:    return Color.roseGold
        case .warning: return Color.roseGold
        case .error:   return Color.roseDeep
        }
    }

    static func border(_ style: BrandBannerStyle) -> Color {
        switch style {
        case .info:    return Color.roseGold.opacity(0.4)
        case .warning: return Color.roseGold.opacity(0.75)
        case .error:   return Color.roseDeep
        }
    }

    private var borderWidth: CGFloat {
        switch style {
        case .info:    return 2
        case .warning: return 3
        case .error:   return 3
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Self.icon(style))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Self.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: Spacing.md) {
                        ForEach(actions) { action in
                            Button(action.label, action: action.action)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Self.actionLabel)
                        }
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.fill(style))
        .overlay(
            Rectangle()
                .fill(Self.border(style))
                .frame(width: borderWidth),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}
