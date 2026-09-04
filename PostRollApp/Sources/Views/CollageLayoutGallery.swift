import SwiftUI

// Lifted out of CaptionReviewView.swift (#718), where it was the last thing in
// that file still holding the progress of a call across to Python.

/// Renders several candidate collage layouts for a day and lets the user pick
/// one. The picked layout's seed is stored as the day's collage seed so the
/// final render reproduces it.
struct CollageLayoutGallery: View {
    let event: Event
    let day: DayName
    var onPick: (Int) -> Void
    var onCancel: () -> Void

    /// The render belongs to the app, not to this sheet (#718).
    ///
    /// It kept the in flight flag, the error and the candidates itself, so
    /// closing the sheet, or switching events with it open, threw a real render
    /// away part way through. The results have had somewhere app scoped to live
    /// since #61; this reads both from their owner.
    @Environment(CollageLayoutLoader.self) private var loader

    private var isLoading: Bool { loader.isRunning(event: event, day: day) }
    private var error: String? { loader.failure(event: event, day: day) }
    private var candidates: [CollageCandidate] {
        loader.candidates(event: event, day: day) ?? []
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a layout: \(day.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
            }
            .padding(Spacing.lg)

            Divider()

            if isLoading {
                VStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.large).tint(PaintedSurfaces.iconAccent)
                    Text("Rendering layout options…")
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(candidates, id: \.seed) { candidate in
                            Button { onPick(candidate.seed) } label: {
                                candidateThumb(candidate)
                            }
                            .buttonStyle(.plain)
                            .help("Use this layout")
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .frame(width: 580, height: 660)
        .background(PaintedSurfaces.page)
        // Asking is all this sheet does. The loader decides whether there is
        // anything to render: reopening an unchanged day must show the SAME
        // options rather than a fresh set (#61), and a render already going is
        // not started again.
        .onAppear { loader.start(event: event, day: day) }
    }

    @ViewBuilder
    private func candidateThumb(_ candidate: CollageCandidate) -> some View {
        CollageCandidateThumb(path: candidate.path)
    }

    /// Identity of the layout inputs: the day, its photos (in order), and their
}


/// One rendered collage option in the gallery grid.
///
/// A view of its own rather than a `@ViewBuilder` helper, because the load has
/// to be a `.task` and a task needs somewhere to put its result (#966). As a
/// helper this called `NSImage(contentsOfFile:)` in the body, so every redraw
/// of the sheet decoded a full collage render synchronously on the main thread,
/// once per option on screen.
struct CollageCandidateThumb: View {
    let path: String
    @State private var load: ImageLoad = .loading

    var body: some View {
        Group {
            switch load {
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .stroke(PaintedSurfaces.treatmentTileBorder, lineWidth: 1)
                    )
            case .loading:
                LoadingPhotoPlaceholder()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .frame(height: 220)
            case .missing:
                // A render that is not on disk is not a slow render. It used to
                // draw as an empty tile, which reads as an option still coming
                // (L10).
                MissingPhotoBadge(label: "render missing")
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .frame(height: 220)
            }
        }
        // 300pt: the grid is `.adaptive(minimum: 150)` inside a 580pt sheet, so
        // a column is never wider than twice its minimum before the grid splits
        // it again.
        .task(id: path) {
            load = await ImageLoad.read(URL(fileURLWithPath: path), fitting: 300)
        }
    }
}
