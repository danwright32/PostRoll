import SwiftUI

/// The reel length on a slider, a second at a time (#1415).
///
/// Opened from "Reel length…" in both of Thursday's post options menus, which
/// used to carry six presets each. A menu cannot hold a slider, so the item
/// opens this instead, and both menus open the same one so the two cannot
/// drift apart the way their preset lists could.
///
/// Every change rebuilds the reel, so the value is committed when the slider
/// is let go, never on each step of a drag. While dragging, the seconds and
/// the pace sentence, read from the strip's layout, follow the thumb, so
/// the place where the reel stops being too fast can be found before letting
/// go. Closing the popover commits too, which is what a keyboard adjustment
/// needs, since arrow keys never report the end of an edit.
struct ReelLengthPopover: View {
    /// The whole reel's length now, holds included (#1433).
    let current: Double
    let isRegenerating: Bool
    /// The strip's layout sidecar, which the pace sentence is read from.
    /// Both menus pass it, so both popovers say the same thing (#1420).
    let layoutURL: URL?
    let onCommit: (Double) -> Void

    @State private var layout: ReelStripLayout?

    @State private var draft: Double = ScrollReelTiming.reelLengthRange.lowerBound
    /// What this popover last committed, so closing it after a release does
    /// not ask for the same rebuild twice while `current` is still catching up.
    @State private var lastCommitted: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                // Continuous, with the seconds kept whole by snapping: a
                // stepped Slider draws a tick for every second (#1420).
                Slider(value: Binding(get: { draft },
                                      set: { draft = ScrollReelTiming.snappedReelLength($0) }),
                       in: ScrollReelTiming.reelLengthRange) { editing in
                    if !editing { commit() }
                }
                .tint(PaintedSurfaces.iconAccent)
                .disabled(isRegenerating)
                .accessibilityLabel("Reel length")
                .accessibilityValue("\(Int(draft.rounded())) seconds")

                Text("\(Int(draft.rounded()))s")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(PaintedSurfaces.bodyText)
                    .frame(width: 32, alignment: .trailing)
            }

            if isRegenerating {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Rebuilding the reel at \(Int(draft.rounded())) seconds…")
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
            } else if let notice = layout?.paceNotice(reelSeconds: draft) {
                Text(notice)
                    .font(.light(11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
        .frame(width: 300)
        .onAppear { draft = current }
        .task(id: layoutURL) {
            guard let layoutURL else { layout = nil; return }
            layout = await Task.detached { ReelStripLayout.load(from: layoutURL) }.value
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let value = ScrollReelTiming.reelLengthToCommit(
            draft: draft, current: lastCommitted ?? current) else { return }
        lastCommitted = value
        onCommit(value)
    }
}

extension View {
    /// Hangs the reel length popover off this view, for the "Reel length…"
    /// item in the menu it is applied to.
    ///
    /// Anchored on a clear view behind the menu rather than on the menu itself:
    /// a `Menu` is drawn by AppKit as a pop up button, and a popover attached
    /// to it directly was never presented, seen in the running app on
    /// 2026-09-26. The caller also sets `isPresented` on the next turn of the
    /// run loop, after the menu has finished closing.
    func reelLengthPopover(isPresented: Binding<Bool>,
                           current: Double?,
                           isRegenerating: Bool,
                           layoutURL: URL?,
                           onCommit: ((Double) -> Void)?) -> some View {
        background {
            Color.clear
                .popover(isPresented: isPresented, arrowEdge: .bottom) {
                    if let current, let onCommit {
                        ReelLengthPopover(current: current,
                                          isRegenerating: isRegenerating,
                                          layoutURL: layoutURL,
                                          onCommit: onCommit)
                    }
                }
        }
    }
}
