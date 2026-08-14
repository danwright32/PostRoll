import SwiftUI

/// The warning that the PostRoll being run is older than the code.
///
/// Centred over the window rather than tucked into a corner: it is the one
/// thing that explains "the fix you asked for is not in this app", and a quiet
/// line somewhere is exactly what gets missed while the wrong build is used all
/// day.
///
/// Shown once per launch, only when the app is definitely behind. Not knowing
/// goes to the log: a popup that cannot say anything actionable is one that
/// gets dismissed on reflex, and the real warning goes with it.
struct BuildBehindSheet: View {
    let builtAt: Date
    let latestCommit: Date
    /// What actually fixes it, which decides both the sentence and the command
    /// below: rebuilding a checkout that is itself behind changes nothing.
    let remedy: BuildFreshness.Remedy
    let repo: URL

    private var command: String {
        BuildFreshness.command(for: remedy, repo: repo)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ZStack {
            Color.cream.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(PaintedSurfaces.iconAccent)
                        Text("PostRoll is out of date")
                            .font(.signPainter(28))
                            .foregroundStyle(Color.warmDark)
                    }
                    RoseGoldDivider()
                }

                Text(BuildFreshness.message(builtAt: builtAt,
                                            latestCommit: latestCommit,
                                            remedy: remedy))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.warmDark)
                    .fixedSize(horizontal: false, vertical: true)

                // The command on its own line, in the shape it is typed, so it
                // can be read straight off the screen as well as copied.
                Text(command)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.warmDark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .fill(Color.creamDeep)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .strokeBorder(Color.creamEdge, lineWidth: 1)
                            )
                    )

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    // The copy confirms it happened. A button that looks the
                    // same before and after pressing it reads as broken, and
                    // the clipboard gives no sign of its own.
                    Button(copied ? "Command copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.link)
                    .disabled(copied)

                    Spacer()

                    Button("Carry on for now") { dismiss() }
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.xl)
        }
        // Sized for the longer of the two states: the pull command carries an
        // absolute path, so it wraps to a second line, and the sentence
        // explaining why a rebuild alone is not enough is two lines longer. A
        // notice that gets clipped is one that was never shipped (L79).
        .frame(width: 480, height: 380)
    }
}
