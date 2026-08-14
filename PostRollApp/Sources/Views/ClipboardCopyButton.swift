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

    /// What was last put on the clipboard from this button, not whether
    /// something was.
    ///
    /// The acknowledgment is then DERIVED by comparing it to the text as it
    /// stands now, rather than being an event that has to be cancelled when the
    /// text changes (L14). A stale checkmark is worse than none: it is an
    /// acknowledgment of something that is no longer true (#205, L12), and
    /// there is no path here on which it can be left standing.
    @State private var copiedText: String? = nil

    private var copied: Bool {
        CopyAcknowledgement.stillDescribesTheClipboard(copied: copiedText, current: text)
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedText = text
        } label: {
            Image(systemName: CopyAcknowledgement.symbol(copied: copied))
                .font(.system(size: size))
                .foregroundStyle(copied ? PaintedSurfaces.iconAccent : Color.warmMid)
        }
        .buttonStyle(.plain)
        .help(CopyAcknowledgement.label(copied: copied, what: what))
        .accessibilityLabel(CopyAcknowledgement.label(copied: copied, what: what))
    }
}

/// What a copy button shows, decided outside the view so it can be asserted.
enum CopyAcknowledgement {

    /// Whether an acknowledgment still describes what is on the clipboard.
    ///
    /// False the moment the text is edited, because the clipboard then holds
    /// something other than what is on screen and a checkmark beside it would
    /// be a claim about the wrong words.
    static func stillDescribesTheClipboard(copied: String?, current: String) -> Bool {
        guard let copied else { return false }
        return copied == current
    }

    /// The icon. Two different glyphs, so the two states are not distinguished
    /// by colour alone.
    static func symbol(copied: Bool) -> String {
        copied ? "checkmark" : "doc.on.doc"
    }

    /// The name, used for both the tooltip and the accessible label, so what a
    /// sighted person reads and what VoiceOver says cannot disagree.
    static func label(copied: Bool, what: String) -> String {
        copied ? "\(what) copied" : "Copy \(what)"
    }
}
