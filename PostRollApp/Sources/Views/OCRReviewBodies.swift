import SwiftUI

/// The parts of the OCR review screen that only say things, pulled out of
/// `OCRReviewView` so they can be rendered and measured outside the running app
/// (#396).
///
/// The editors stay in the screen: they are bindings into the draft being
/// corrected, which is behaviour. What comes out here is the column of notices at
/// the top and the bar at the bottom, which is where every state Dan can only
/// reach with a bad program lives.

/// What the OCR review screen says before Dan starts correcting anything.
///
/// Five slots, and they stack rather than replace each other, because a program
/// can be thin AND knowingly incomplete AND have had its spell check skipped, and
/// each of those is a different thing to know.
struct OCRReviewNotices: View {
    /// From `OCRReviewReadiness.detectedIssues`, never written here.
    var detectedIssues: [String]? = nil
    /// Programs taken knowingly incomplete (#378), each already worded by
    /// `ProgramShortfall`.
    var partialProgramNotes: [String] = []
    /// Why names were not spell-checked, already worded by the readiness type.
    var visionSkippedMessage: String? = nil
    /// Why the event's website was not read for performers, already worded by
    /// the readiness type (#449).
    var webPerformersSkippedMessage: String? = nil
    /// Auto-flagging failed, already worded by the readiness type.
    var flagErrorMessage: String? = nil
    /// Closing the gap a partial scan left, when there is one (#518).
    var rescan: RescanOffer? = nil

    /// The offer to read just the pages that went unread.
    ///
    /// Carries its own refusal rather than only a disabled flag, because a
    /// control that is greyed out with the reason computed somewhere else
    /// leaves Dan with a dead button and nothing on screen connecting the two
    /// (L109).
    struct RescanOffer {
        let title: String
        /// Why it cannot run, or nil when it can.
        let refusal: String?
        /// What it will not read even though it can run, or nil when it will
        /// read the whole gap. Carried beside the button rather than instead of
        /// it, because these pages do not stop the others being read and a page
        /// left out with nothing said would sit in the gap unexplained (#575).
        let note: String?
        let isRunning: Bool
        let action: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let detectedIssues, !detectedIssues.isEmpty {
                BrandBanner(
                    icon: "exclamationmark.circle",
                    message: detectedIssues.joined(separator: " "),
                    style: .error
                )
            }

            // A program Dan knowingly took incomplete. Shown here rather than
            // only at import, because this is the screen where the program data
            // is judged, and a cast list that looks thin needs to read as
            // explained rather than as all there is (#378).
            ForEach(partialProgramNotes, id: \.self) { note in
                BrandBanner(icon: "doc.badge.ellipsis", message: note, style: .warning)
            }

            // Directly under the notice it acts on, because an action that
            // names a target has to be reachable from the surface naming it,
            // and a durable condition needs a durable control rather than one
            // hanging off a message that clears (L80, L126).
            if let rescan {
                if let refusal = rescan.refusal {
                    BrandBanner(icon: "questionmark.folder", message: refusal,
                                style: .warning)
                } else {
                    if let note = rescan.note {
                        BrandBanner(icon: "questionmark.folder", message: note,
                                    style: .warning)
                    }
                    Button(action: rescan.action) {
                        Label(rescan.isRunning ? "Reading the missing pages…" : rescan.title,
                              systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(rescan.isRunning)
                    .help("Reads only the pages the earlier scan could not, and "
                          + "adds them to what is already here.")
                }
            }

            if let webPerformersSkippedMessage {
                BrandBanner(icon: "globe",
                            message: webPerformersSkippedMessage, style: .warning)
            }

            if let visionSkippedMessage {
                BrandBanner(icon: "text.magnifyingglass",
                            message: visionSkippedMessage, style: .warning)
            }

            if let flagErrorMessage {
                BrandBanner(icon: "exclamationmark.triangle",
                            message: flagErrorMessage, style: .error)
            }
        }
    }
}

/// The bar that ends OCR review.
///
/// Takes the label, the help text and the count rather than deriving any of
/// them, so the words and the disabled state come from one place
/// (`OCRReviewReadiness`) and cannot disagree.
struct OCRConfirmBar: View {
    let label: String
    let help: String
    let unresolvedFlagCount: Int
    var onConfirm: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.sm) {
            // The reason, on screen rather than only in a tooltip. A disabled
            // button beside nothing explaining it is a dead control, and a
            // hover-only explanation is one nobody finds (L109, L49).
            if unresolvedFlagCount > 0, !help.isEmpty {
                Text(help)
                    .font(.light(11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(label, action: onConfirm)
                    .buttonStyle(BrandButtonStyle())
                    .disabled(unresolvedFlagCount > 0)
                    .help(help)
            }
        }
    }
}
