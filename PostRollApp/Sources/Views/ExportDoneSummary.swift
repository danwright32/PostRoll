import SwiftUI
import AppKit

/// What the export screen shows once a run has finished.
///
/// Its own view, taking plain values and two closures rather than reaching for
/// AppState and ExportManager, so it can be rendered and measured outside the
/// running app (#393). The screens that mattered most today were exactly the
/// ones no check could draw, because drawing them meant standing up the whole
/// application first.
///
/// Nothing here decides anything: an export that lost files is not a completed
/// export, so it does not get the checkmark, the word "complete", or the claim
/// that the event is archived, and that rule lives in `isIncomplete` where it
/// can be read (#79).
struct ExportDoneSummary: View {
    let folderName: String
    let mediaError: String?
    let mediaWarning: String?
    var onBack: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onDone: () -> Void = {}

    /// An export that lost files. Named rather than inlined three times, so the
    /// mark, the heading and the archive sentence cannot disagree about it.
    var isIncomplete: Bool { mediaError != nil }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // A route back into the event, matching the ready screen. Without
            // it a finished export trapped the event: the detail pane routes on
            // the stage, the stage is .exported, so this was the only reachable
            // screen and the only way out was quitting the app (#182).
            HStack {
                StageBackButton(label: "Back to caption review", action: onBack)
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)

            Spacer().frame(height: Spacing.lg)

            Image(systemName: isIncomplete ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(isIncomplete ? Color.roseDeep : Color.roseGold.opacity(0.7))
                .padding(.top, Spacing.xl)

            Text(isIncomplete ? "Export incomplete" : "Export complete")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)

            Text(folderName)
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            RoseGoldDivider()
                .frame(width: 80)

            if let mediaError {
                // The message is whatever actually failed. It used to append
                // "Check that ffmpeg is installed" to every cause, which sends
                // the diagnosis somewhere unrelated for a missing photo.
                BrandBanner(
                    icon: "exclamationmark.triangle",
                    message: "The captions and blog were exported. \(mediaError)",
                    style: .error
                )
                .frame(maxWidth: 400)
            }

            // An input that was missing while the day rendered anyway. Said out
            // loud, because a file that has moved is worth knowing about, and
            // deliberately NOT as an error: the folder is complete and the
            // event is archived (#265).
            if let mediaWarning {
                BrandBanner(icon: "info.circle", message: mediaWarning, style: .warning)
                    .frame(maxWidth: 400)
            }

            Text(isIncomplete
                 ? "This event has NOT been archived, so nothing is on the clock to be cleaned up. Fix what's listed above and export again."
                 : "This event is now archived. Use the archive button in the sidebar to revisit it.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: Spacing.md) {
                Button("Open in Finder", action: onOpenFolder)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
                Button("Done", action: onDone)
                    .buttonStyle(BrandButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }
}
