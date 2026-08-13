import SwiftUI
import AppKit

/// The three states a file-backed image actually has (#461).
///
/// Every thumbnail and overlay in the app held a plain `NSImage?` and rendered a
/// spinner while it was nil. `NSImage(contentsOf:)` returns nil for a file that
/// has moved or been reclaimed as well as for one that has not been read yet, so
/// the spinner ran forever with nothing distinguishing loading from gone. A
/// missing file is an ordinary state here: `ArchiveCleanup` reclaims photos 60
/// days after export, and `MissingMediaScan` exists precisely because they go
/// missing. An error state and an empty state are different screens (L10).
///
/// One type rather than a `loadFailed` bool beside each optional, because the
/// pair can disagree and the version of this fix that landed in
/// `PhotoAssignmentView`'s thumbs did not reach any of its siblings (L30).
enum ImageLoad: Equatable {
    case loading
    case loaded(NSImage)
    /// Read, and not there. Never "not read yet".
    case missing

    /// Read `url` off the main thread and say which of the three happened.
    static func read(_ url: URL) async -> ImageLoad {
        let loaded = await Task.detached { NSImage(contentsOf: url) }.value
        return loaded.map(ImageLoad.loaded) ?? .missing
    }

    /// For call sites that already loaded the image alongside something else.
    static func of(_ image: NSImage?) -> ImageLoad {
        image.map(ImageLoad.loaded) ?? .missing
    }

    var image: NSImage? {
        if case .loaded(let image) = self { return image }
        return nil
    }

    var isMissing: Bool { self == .missing }
}

/// What a thumbnail shows in place of a file that is not there.
///
/// Shared rather than private to one screen: it was private to
/// `PhotoAssignmentView`, which is why six sibling views kept spinning forever
/// instead of using it.
struct MissingPhotoBadge: View {
    /// Sized to its frame, so the same badge reads correctly at 80pt and in a
    /// full-width preview.
    var iconSize: CGFloat = 14
    var labelSize: CGFloat = 8

    var body: some View {
        Color.creamDeep.overlay {
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(Color.roseGold.opacity(0.85))
                Text("missing")
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundStyle(Color.warmMid)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This file is missing")
    }
}

/// The loading half, so the two placeholders are declared side by side and
/// neither can quietly become the other.
struct LoadingPhotoPlaceholder: View {
    var body: some View {
        Color.creamDeep
            .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }
}

extension ImageLoad {
    /// The whole three-state thumbnail, so a call site cannot render two of the
    /// three and leave the missing case looking like loading.
    @ViewBuilder
    func thumbnail(iconSize: CGFloat = 14, labelSize: CGFloat = 8) -> some View {
        switch self {
        case .loaded(let image):
            Image(nsImage: image).resizable().scaledToFill()
        case .loading:
            LoadingPhotoPlaceholder()
        case .missing:
            MissingPhotoBadge(iconSize: iconSize, labelSize: labelSize)
        }
    }
}
