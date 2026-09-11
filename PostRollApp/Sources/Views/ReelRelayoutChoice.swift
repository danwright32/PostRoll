import SwiftUI

/// The choice put to Dan when exporting would lay a reel out differently from
/// the video he approved (#1407).
///
/// Its own view taking plain values and two closures, like `ExportDoneSummary`,
/// so it can be rendered and measured without standing up the application. The
/// screens that went unread longest were the ones nothing could draw.
///
/// Both routes out are here and neither is a dismissal. A surface that can be
/// closed without answering leaves the export in a state nobody chose, and the
/// only way back to it is pressing Export again and meeting the same question.
struct ReelRelayoutChoice: View {
    let message: String
    /// Whether the video that exists can actually be exported as it stands.
    /// When it cannot, the only honest control is the one that makes it again.
    let canKeepApproved: Bool
    var onKeep: () -> Void = {}
    var onRelayOut: () -> Void = {}

    /// Whether making the reel again is drawn as the emphasised control.
    ///
    /// It is, and only, when it is the ONLY way forward. A screen whose sole
    /// route out is a plain link does not look like it has one at all, and the
    /// reason for playing it down elsewhere (it is the choice that cannot be
    /// undone) does not apply where there is nothing to choose between (L49).
    ///
    /// Named rather than inlined so the rule can be read and tested without
    /// standing up the view.
    var relayOutIsPrimary: Bool { !canKeepApproved }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.lg)

            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(PaintedSurfaces.pageAccentText)

            Text("This reel will come out different")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)

            BrandBanner(icon: "exclamationmark.triangle", message: message, style: .warning)
                .frame(maxWidth: 420)

            HStack(spacing: Spacing.md) {
                if relayOutIsPrimary {
                    Button("Make it again") { onRelayOut() }
                        .buttonStyle(BrandButtonStyle())
                } else {
                    // Beside a way out that keeps the video, the quiet control
                    // is the one that cannot be undone, so it does not carry
                    // the weight that reads as the safe way on (L609).
                    Button("Make it again") { onRelayOut() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                    Button("Keep the video I approved") { onKeep() }
                        .buttonStyle(BrandButtonStyle())
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
