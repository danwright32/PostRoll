import SwiftUI

/// The parts of caption review that only say things, pulled out of
/// `CaptionReviewView` so they can be rendered and measured outside the running
/// app (#396).
///
/// The day sections and the blog section stay in the screen: they are bindings
/// into the draft being edited. What comes out here is the notices and the bar at
/// the bottom, which between them hold every state that needs a broken run, a
/// moved file or a rebuild in flight to reach.

/// What the bottom of caption review is doing.
///
/// Two cases rather than a bool, because a bar that cannot export and a bar that
/// can are different offers and used to be told apart by an if-else nobody could
/// draw. The three long-run states (captions regenerating, graphics generating,
/// edits under review) stay in the screen: those are `LongRunIndicator`, which is
/// already its own view taking plain values and has its own tests.
enum CaptionReviewActivity: Equatable {
    /// A per-day rebuild is still running, so exporting now would copy the
    /// previous version of it (#89). Carries the reason, from
    /// `ExportReadiness.blockedReason`.
    case waitingOnRebuild(reason: String)
    /// Nothing in the way. Carries a failed graphics run if there was one, since
    /// that error and the ready state occupy the same place on screen.
    case ready(graphicsError: String?)
}

/// The bar that ends caption review.
struct CaptionReviewActionBar: View {
    let activity: CaptionReviewActivity
    var onRetryGraphics: () -> Void = {}
    var onDismissGraphicsError: () -> Void = {}
    var onRegenerateAll: () -> Void = {}
    var onApprove: () -> Void = {}

    var body: some View {
        switch activity {
        case .waitingOnRebuild(let reason):
            // A per-day rebuild is the longest running of these and was the one
            // the bar did not consult, so Approve and Export stayed live and
            // copied the pre-rebuild file (#89).
            // The two sentences stack and wrap rather than sitting on one line.
            // Rendered through AppKit for the first time in #404, this bar wanted
            // 654pt whatever it was given and truncated below that, so at any
            // window narrower than about 920pt Dan read "Waiting for the Wednesday
            // and..." and never learned which days or why (L79).
            HStack(alignment: .top, spacing: Spacing.sm) {
                ProgressView().controlSize(.small).tint(Color.roseGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(reason)…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.warmDark)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Exporting now would copy the previous version.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.xl)

        case .ready(let graphicsError):
            VStack(spacing: 0) {
                // A preview run that died used to be indistinguishable from one
                // that never started: the error went into a `try?` and the screen
                // just showed no graphics (#75).
                if let graphicsError {
                    BrandBanner(
                        icon: "exclamationmark.triangle",
                        message: "The story graphics couldn't be generated: "
                               + Sentence.closed(graphicsError),
                        style: .error,
                        actions: [
                            BrandBannerAction(label: "Try again", action: onRetryGraphics),
                            BrandBannerAction(label: "Dismiss", action: onDismissGraphicsError),
                        ]
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.sm)
                }
                HStack {
                    // Quieter than the filled primary beside it, which is the
                    // decision on this screen, but still visibly a control: it
                    // throws away every edit and pays for a fresh week. The rule
                    // is written down beside HaltChoiceEmphasis (#398).
                    Button("Regenerate All…", action: onRegenerateAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseGold)
                    Spacer()
                    Button("Approve & Export", action: onApprove)
                        .buttonStyle(BrandButtonStyle())
                }
                .padding(Spacing.xl)
            }
        }
    }
}

/// A day that finished with something worth saying about it.
struct CaptionReviewDayNotice: Identifiable, Equatable {
    /// The day's key, so two notices about one day cannot collide in a ForEach.
    let id: String
    /// Already prefixed with the day name by the producer.
    let message: String
}

/// What caption review says between the content and the bar.
///
/// Warnings, not errors, on purpose: each of these days rendered and its captions
/// are usable, and before #265 the graphics one arrived as "regeneration failed",
/// which it had not been.
struct CaptionReviewNotices: View {
    /// A run count that failed on the generation step, worded by the screen.
    var failedDayCount: Int = 0
    /// The last regeneration error, if one is still current.
    var regenerateError: String? = nil
    /// Days that generated but left a photo out because the file would not open
    /// (#228). Without this the skip is invisible, because a short alt text list
    /// looks like an ordinary one.
    var skippedPhotoNotices: [CaptionReviewDayNotice] = []
    /// Days whose assets finished while an OPTIONAL input had moved (#265).
    var mediaWarnings: [CaptionReviewDayNotice] = []

    /// The banner about failed days, worded here so the count and the sentence
    /// cannot disagree.
    var failedDaysMessage: String? {
        guard failedDayCount > 0 else { return nil }
        return "\(failedDayCount) day\(failedDayCount == 1 ? "" : "s") failed to generate. "
             + "You can re-run generation from the previous step."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let failedDaysMessage {
                BrandBanner(icon: "exclamationmark.triangle",
                            message: failedDaysMessage, style: .error)
            }
            if let regenerateError {
                BrandBanner(icon: "exclamationmark.triangle",
                            message: regenerateError, style: .error)
            }
            ForEach(skippedPhotoNotices) { notice in
                BrandBanner(icon: "photo.badge.exclamationmark", message: notice.message)
            }
            ForEach(mediaWarnings) { notice in
                BrandBanner(icon: "photo.badge.exclamationmark", message: notice.message)
            }
        }
    }
}
