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
                .foregroundStyle(isIncomplete ? PaintedSurfaces.pageAccentText : PaintedSurfaces.iconAccent.opacity(0.7))
                .padding(.top, Spacing.xl)

            Text(isIncomplete ? "Export incomplete" : "Export complete")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)

            Text(folderName)
                .font(.light(12))
                .foregroundStyle(PaintedSurfaces.secondaryText)

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

            ExportArchiveNote(isIncomplete: isIncomplete)

            HStack(spacing: Spacing.md) {
                Button("Open in Finder", action: onOpenFolder)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                Button("Done", action: onDone)
                    .buttonStyle(BrandButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }
}

/// Whether the event was archived, and what to do next when it was not.
///
/// Its own view so its wrapping can be measured directly (#411). Inside the
/// summary it could only be checked through the whole screen, and the whole
/// screen's height does not move when this line truncates, because the line is
/// capped at 300pt whatever the window is doing. So the defect was invisible to
/// every measurement taken from the outside, and was found by looking at the
/// rendered page: it read "This event has NOT been archived, so nothing is on
/// the cloc..." and the half naming the fix was gone.
struct ExportArchiveNote: View {
    let isIncomplete: Bool

    var message: String {
        isIncomplete
            ? "This event has NOT been archived, so nothing is on the clock to be cleaned up. "
              + "Fix what's listed above and export again."
            : "This event is now archived. Use the archive button in the sidebar to revisit it."
    }

    /// The width this line is held to, whatever the window is doing. Named
    /// because the test measures at exactly this width: anywhere else would be
    /// measuring a layout the app never uses.
    static let width: CGFloat = 300

    var body: some View {
        Text(message)
            .font(.light(11))
            .foregroundStyle(PaintedSurfaces.secondaryText)
            .multilineTextAlignment(.center)
            // Order matters. The width has to be capped BEFORE the height is
            // allowed to grow, or the text is already laid out on one ideal line
            // and the cap only clips it.
            .frame(maxWidth: Self.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}
