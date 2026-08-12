import SwiftUI

enum BrandBannerStyle {
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

    private var borderColor: Color {
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
    private var bgColor: Color {
        switch style {
        case .info:    return Color.roseGold.opacity(0.07)
        case .warning: return Color.roseGold.opacity(0.10)
        case .error:   return Color.roseDeep.opacity(0.08)
        }
    }
    private var iconColor: Color {
        switch style {
        case .info:    return Color.roseGold
        case .warning: return Color.roseGold
        case .error:   return Color.roseDeep
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: Spacing.md) {
                        ForEach(actions) { action in
                            Button(action.label, action: action.action)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.roseGold)
                        }
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgColor)
        .overlay(
            Rectangle()
                .fill(borderColor)
                .frame(width: borderWidth),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}
