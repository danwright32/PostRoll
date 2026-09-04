import SwiftUI
import AppKit
import CoreGraphics
import ImageIO

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

    /// Read `url`, decoded to fit `points`, and say which of the three
    /// happened.
    ///
    /// `points` is the longest edge this image will actually be DRAWN at, and
    /// it is required rather than defaulted, because a loader that guesses is
    /// how the app came to hold 4.2 megapixel bitmaps behind 80pt squares
    /// (#966). Every caller knows its own frame; nothing here can.
    ///
    /// What this fixes is not the read, it is the DRAW. `NSImage(data:)` keeps
    /// the compressed bytes and decodes them lazily, inside the CoreAnimation
    /// commit, on the main thread. macOS discards SwiftUI's cached image
    /// surfaces whenever the app leaves the foreground, so coming back decoded
    /// every visible photo again from scratch before the window could draw:
    /// measured on the running app on 2026-08-29, 890 of 19,884 main thread
    /// samples were inside `JPEGDecompressSurface` under `CA::Transaction::commit`,
    /// and the app's own Swift code accounted for 16 samples in the whole
    /// profile. The application code was never the cost.
    ///
    /// So the image handed back is decoded ALREADY, and decoded SMALL. Both
    /// halves matter: small alone would still decode lazily on the main thread,
    /// and decoded alone would still be a full frame texture per thumbnail.
    ///
    /// The DECODED IMAGE crosses the actor boundary, not the bytes. `NSImage`
    /// is not Sendable, which is why this used to hand back `Data` and decode
    /// on arrival, but decoding on arrival is decoding on the main actor, which
    /// is the thing being removed. `CGImage` is immutable once ImageIO returns
    /// it, so it crosses in a box that says so.
    ///
    /// `@MainActor` because `ImageLoad` holds an `NSImage` and so is not
    /// Sendable either. Every call site is a SwiftUI `.task`, already on the
    /// main actor.
    @MainActor
    static func read(_ url: URL, fitting points: CGFloat) async -> ImageLoad {
        let pixels = pixelSize(for: points)
        guard let decoded = await ThumbnailStore.shared.image(for: url, maxPixel: pixels)
        else { return .missing }
        return .loaded(NSImage(cgImage: decoded.cgImage, size: decoded.declaredSize))
    }

    /// The longest edge in PIXELS to decode for a frame `points` wide.
    ///
    /// Taken from the widest backing scale any attached screen has rather than
    /// the main one, because a window dragged to a Retina display would
    /// otherwise show an image decoded for the other one, and the two failures
    /// are not symmetrical: too many pixels costs memory, too few is visibly
    /// soft. Two rather than one where no screen answers, for the same reason.
    @MainActor
    static func pixelSize(for points: CGFloat) -> Int {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return Int((points * max(scale, 1)).rounded(.up))
    }

    /// The longest edge, in points, of the largest screen attached.
    ///
    /// For the one surface that draws a photo as large as the machine can show
    /// it. A number written down here instead would be right on the display it
    /// was written on and soft on a bigger one, with nothing reporting it
    /// (L221): the constraint belongs to the hardware, so it is read from the
    /// hardware. 1400 where no screen answers, which is a full height window on
    /// the laptop this is built on.
    @MainActor
    static var largestScreenPoints: CGFloat {
        NSScreen.screens.map { max($0.frame.width, $0.frame.height) }.max() ?? 1400
    }

    /// Decode `url` down to `maxPixel` on its longest edge, or nil when the
    /// file is not there and not readable as an image.
    ///
    /// `kCGImageSourceShouldCacheImmediately` is the whole point: without it
    /// ImageIO hands back an image that has not been decoded yet and the decode
    /// lands wherever it is first drawn, which is the main thread. With it the
    /// decode happens HERE, off the main actor, once.
    ///
    /// `CreateThumbnailFromImageAlways` rather than `IfAbsent`, because the
    /// embedded EXIF thumbnail in a camera JPEG is around 160px and would be
    /// upscaled into any frame larger than that.
    nonisolated static func decode(_ url: URL, maxPixel: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        else { return nil }
        return DecodedImage(cgImage: image,
                            declaredSize: sourceSize(source) ?? NSSize(width: image.width,
                                                                       height: image.height))
    }

    /// The size the FULL image would report, read from the file's header
    /// without decoding it.
    ///
    /// This is what the `NSImage` handed back is given as its size, rather than
    /// the thumbnail's own pixel count. Several call sites compute geometry
    /// from `image.size`: the collage cell overlay derives the crop overflow
    /// from it and says in its own comment that it is the same arithmetic as
    /// Python's `effective_scale`, which reads the original file. Handing those
    /// a thumbnail's rounded dimensions would move the preview a little away
    /// from what actually renders, in a way nothing measures and nobody would
    /// connect to a change about decoding (L263).
    ///
    /// Orientations 5 to 8 are the transposed ones, and the pixel dimensions in
    /// the header are pre-rotation, so they are swapped here. The thumbnail
    /// itself is already rotated, by `CreateThumbnailWithTransform`.
    private nonisolated static func sourceSize(_ source: CGImageSource) -> NSSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let transposed = (5...8).contains(orientation)
        return NSSize(width: transposed ? height : width,
                      height: transposed ? width : height)
    }

    /// A decoded image on its way back from the reader.
    ///
    /// `CGImage` is immutable from the moment ImageIO returns it and
    /// CoreGraphics does not annotate it as Sendable, so the crossing is
    /// spelled out here rather than left implied: nothing writes to this after
    /// `decode` returns it, and the only thing done with it is reading its
    /// pixels to draw.
    struct DecodedImage: @unchecked Sendable {
        let cgImage: CGImage
        /// What the FULL image measures, so an `NSImage` built from this
        /// reports the same size it did before any of this existed.
        let declaredSize: NSSize

        /// Roughly what this costs to keep, for the cache's byte budget.
        /// Four bytes a pixel: the exact layout varies, the order of magnitude
        /// does not, and a budget is only ever an order of magnitude.
        var byteCost: Int { cgImage.width * cgImage.height * 4 }
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
    /// What it is that has gone. A parameter because the program upload screen
    /// had grown its own copy of this badge saying "File missing", with a
    /// different icon colour and a label under the level (#586); taking the
    /// wording rather than overwriting it means one implementation without
    /// changing a sentence anybody reads.
    var label: String = "missing"

    var body: some View {
        PaintedSurfaces.photoPlaceholder.overlay {
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(PaintedSurfaces.missingPhotoIcon)
                Text(label)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
        PaintedSurfaces.photoPlaceholder
            .overlay { ProgressView().controlSize(.small)
                .tint(PaintedSurfaces.photoPlaceholderSpinner) }
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
