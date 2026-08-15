import SwiftUI

/// A photo opened at full size, over whatever screen opened it.
///
/// One view, used by caption review and by photo assignment (#602). It was two,
/// 97% identical, and the 3% was a behaviour nobody chose: one of them closed on
/// Escape and the other did not, so the same photo opened the same way answered
/// the same key differently depending on which screen it came from. Every colour
/// on its missing-file state also had to be named twice in one change (#598),
/// which is the cost of the second copy showing up in the work rather than in
/// the design.
struct PhotoLightbox: View {
    let url: URL
    let onDismiss: () -> Void

    @State private var load: ImageLoad = .loading

    var body: some View {
        PhotoLightboxBody(url: url, load: load, onDismiss: onDismiss)
            .task { load = await ImageLoad.read(url) }
    }
}

/// The lightbox as a picture of a state, with no loading of its own.
///
/// Split for the reason the generation and export screens are: reaching the
/// missing-file state in a test means waiting on a real read of a real absent
/// file, and a state nothing can draw is a state nobody has ever looked at.
/// `PhotoLightboxTests` renders this one and measures it.
struct PhotoLightboxBody: View {
    let url: URL
    let load: ImageLoad
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            PaintedSurfaces.lightboxBackdrop
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            switch load {
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(48)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 6)
            case .loading:
                ProgressView().tint(PaintedSurfaces.lightboxLabel)
            case .missing:
                // Opened from a thumbnail, so the file was there when the list
                // was drawn. A spinner here reads as a slow load of a photo
                // that is simply gone (L10).
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(PaintedSurfaces.lightboxLabel)
                    Text("This file is missing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.lightboxLabel)
                    // The name is the useful half: it says WHICH file, which is
                    // what makes the message something a person can act on.
                    Text(url.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.lightboxDetail)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(PaintedSurfaces.lightboxCloseIcon,
                                             PaintedSurfaces.lightboxCloseIconDisc)
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close the photo")
                    .help("Close the photo")
                    // Escape closes it, which is the platform's convention and
                    // was true on one of the two screens this used to live on.
                    .keyboardShortcut(.cancelAction)
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}
