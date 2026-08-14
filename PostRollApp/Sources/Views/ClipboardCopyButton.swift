import SwiftUI
import AppKit

/// A copy-to-clipboard button that says the copy landed (#466).
///
/// A button that looks the same before and after being pressed reads as broken,
/// so the person presses it again (L22, L44). #205 fixed exactly this for the
/// blog copy button and wrote the reasoning down; the three per-day caption
/// copy buttons were the siblings that fix skipped (L30).
///
/// It also carries a label, which the icon-only versions did not. An icon with
/// no accessible name is a control VoiceOver can only describe as a button
/// (L20).
///
/// One view rather than three near-identical inline buttons, so the
/// acknowledgment, the label and the staleness reset cannot disagree between
/// them.
struct ClipboardCopyButton: View {

    /// What lands on the clipboard.
    let text: String

    /// What is being copied, as a person would say it: "Sunday caption". Used
    /// for the tooltip and the accessible name, so both say the same thing.
    let what: String

    var size: CGFloat = 10

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size))
                .foregroundStyle(copied ? Color.roseGold : Color.warmMid)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy \(what)")
        .accessibilityLabel(copied ? "\(what) copied" : "Copy \(what)")
        // A stale checkmark would claim the clipboard holds text that has since
        // been edited, which is worse than no acknowledgment at all: it is an
        // acknowledgment of something that is no longer true (#205, L12).
        .onChange(of: text) { copied = false }
    }
}
