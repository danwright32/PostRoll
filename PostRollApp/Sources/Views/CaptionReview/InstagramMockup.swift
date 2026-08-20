import SwiftUI
import AVKit
import AppKit

/// Read-only mockup of how the post will look on Instagram.
/// Updates live as the user edits caption / hashtags in the right column.
struct InstagramMockup: View {
    let photoURL: URL?
    var photoURLs: [URL] = []    // carousel mode: if non-empty, show left/right arrows
    var videoURL: URL? = nil     // reel — shown instead of still photo when set
    /// Bumped on each successful regen — threaded into ReelPreviewPlayer so the
    /// AVPlayer's URL-keyed asset cache is busted even if the file path itself
    /// stays stable (Python overwrites the MP4 in place).
    var videoVersion: Int = 0
    let dayLabel: String   // e.g. "Sunday" — shown as relative post time
    let caption: String
    let hashtags: [String]
    let cardWidth: CGFloat
    /// Reel days use "Regenerate reel" copy and surface the layout / audio / photos
    /// menu items. Non-reel (story) days only get "Regenerate graphic".
    var isReelDay: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var onReviseCaption: (() -> Void)? = nil
    var onNewLayout: (() -> Void)? = nil
    var onSwapAudio: (() -> Void)? = nil
    var onUploadAudio: (() -> Void)? = nil
    var onChangePhotos: (() -> Void)? = nil
    /// Current reel length (scroll seconds) and change handler — drives the
    /// "Reel length" submenu (Thursday scroll reel only). nil hides it.
    var currentReelLength: Double? = nil
    var onChangeReelLength: ((Double) -> Void)? = nil
    /// Optional B&W after controls (Tuesday reel). `hasBW` toggles the label
    /// between "Add" and "Change" and gates the Remove item.
    var onChangeBW: (() -> Void)? = nil
    var onRemoveBW: (() -> Void)? = nil
    var hasBW: Bool = false
    var isRegenerating: Bool = false

    /// Preset reel lengths offered in the menu (scroll seconds, 15–60 range).
    private static let reelLengthPresets: [Int] = [15, 20, 30, 40, 50, 60]

    private var regenerateLabelText: String {
        if isRegenerating { return "Regenerating…" }
        return isReelDay ? "Regenerate reel" : "Regenerate graphic"
    }

    private var menuHasItems: Bool {
        onRegenerate != nil
            || onReviseCaption != nil
            || onNewLayout != nil
            || onSwapAudio != nil
            || onUploadAudio != nil
            || onChangePhotos != nil
            || onChangeReelLength != nil
            || onChangeBW != nil
    }

    @State private var photo: NSImage? = nil
    @State private var carouselIndex: Int = 0

    private var hashtagLine: String {
        hashtags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " ")
    }

    private var isCarousel: Bool { photoURLs.count > 1 }

    private var displayedPhotoURL: URL? {
        if isCarousel {
            let idx = min(max(carouselIndex, 0), photoURLs.count - 1)
            return photoURLs[idx]
        }
        return photoURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 9) {
                // Gradient story-ring avatar with real DW logo
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [PaintedSurfaces.instagramRingWarm,
                                     PaintedSurfaces.instagramRingPink,
                                     PaintedSurfaces.instagramRingViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(PaintedSurfaces.instagramAvatarRing).padding(2)
                    Image("DWAvatar")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .padding(3)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("dwphotony")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PaintedSurfaces.instagramInk)
                    Text("Original audio")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.instagramSecondaryText)
                }

                Spacer()

                if menuHasItems {
                    Menu {
                        if let onRegenerate {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(regenerateLabelText, systemImage: "arrow.clockwise")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onReviseCaption {
                            Button {
                                onReviseCaption()
                            } label: {
                                Label("Revise caption with feedback…", systemImage: "text.bubble")
                            }
                        }
                        if let onNewLayout {
                            Button {
                                onNewLayout()
                            } label: {
                                Label("New layout (re-roll)", systemImage: "shuffle")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onChangeReelLength {
                            Menu {
                                ForEach(Self.reelLengthPresets, id: \.self) { secs in
                                    Button {
                                        onChangeReelLength(Double(secs))
                                    } label: {
                                        if let current = currentReelLength, Int(current.rounded()) == secs {
                                            Label("\(secs)s", systemImage: "checkmark")
                                        } else {
                                            Text("\(secs)s")
                                        }
                                    }
                                }
                            } label: {
                                Label("Reel length", systemImage: "timer")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onChangePhotos {
                            Button {
                                onChangePhotos()
                            } label: {
                                Label("Change photos", systemImage: "photo.on.rectangle.angled")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onChangeBW {
                            Button {
                                onChangeBW()
                            } label: {
                                Label(hasBW ? "Change B&W edit" : "Add B&W edit", systemImage: "circle.lefthalf.filled")
                            }
                            .disabled(isRegenerating)
                        }
                        if hasBW, let onRemoveBW {
                            Button {
                                onRemoveBW()
                            } label: {
                                Label("Remove B&W edit", systemImage: "minus.circle")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onSwapAudio {
                            Button {
                                onSwapAudio()
                            } label: {
                                Label("New Jamendo audio", systemImage: "music.note")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onUploadAudio {
                            Button {
                                onUploadAudio()
                            } label: {
                                Label("Upload my own audio", systemImage: "square.and.arrow.down")
                            }
                            .disabled(isRegenerating)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.instagramGlyph)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Post options")
                    .help("Post options")
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.instagramGlyph)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)

            // ── Photo or reel — fills card width at native aspect ───────────
            // Use explicit dimensions so the card grows vertically to fit the
            // content instead of `scaledToFit` shrinking it when the parent
            // is height-constrained.
            Group {
                if let url = videoURL {
                    // Reel: full 9:16 at card width — card width is already set
                    // to a screen-proportional value so height is controlled.
                    ReelPreviewPlayer(url: url, version: videoVersion, onRegenerate: nil, isRegenerating: isRegenerating)
                        .frame(width: cardWidth, height: cardWidth * 16.0 / 9.0)
                        .overlay {
                            if isRegenerating {
                                ZStack {
                                    PaintedSurfaces.photoScrim
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .controlSize(.large)
                                            .colorScheme(.dark)
                                        Text("Regenerating…")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(PaintedSurfaces.photoScrimText)
                                    }
                                }
                            }
                        }
                } else if let photo {
                    let aspect = photo.size.width / max(photo.size.height, 1)
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: cardWidth, height: cardWidth / max(aspect, 0.01))
                        .overlay(alignment: .leading) {
                            if isCarousel && carouselIndex > 0 {
                                CarouselArrow(systemName: "chevron.left",
                                              label: "Previous photo") {
                                    carouselIndex -= 1
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if isCarousel && carouselIndex < photoURLs.count - 1 {
                                CarouselArrow(systemName: "chevron.right",
                                              label: "Next photo") {
                                    carouselIndex += 1
                                }
                                .padding(.trailing, 8)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isCarousel {
                                Text("\(carouselIndex + 1)/\(photoURLs.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PaintedSurfaces.photoScrimText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(PaintedSurfaces.photoScrim)
                                    )
                                    .padding(8)
                            }
                        }
                } else if displayedPhotoURL != nil {
                    PaintedSurfaces.instagramPlaceholder
                        .frame(width: cardWidth, height: cardWidth)
                        .overlay { ProgressView().controlSize(.small) }
                } else {
                    PaintedSurfaces.instagramPlaceholder
                        .frame(width: cardWidth, height: cardWidth)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 28))
                                .foregroundStyle(PaintedSurfaces.instagramPlaceholderMark)
                        }
                }
            }

            // ── Action bar ──────────────────────────────────────────────────
            HStack(spacing: 14) {
                Image(systemName: "heart")
                    .font(.system(size: 25, weight: .light))
                Image(systemName: "bubble.right")
                    .font(.system(size: 23, weight: .light))
                Image(systemName: "paperplane")
                    .font(.system(size: 22, weight: .light))
                Spacer()
                Image(systemName: "bookmark")
                    .font(.system(size: 22, weight: .light))
            }
            .foregroundStyle(PaintedSurfaces.instagramInk)
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 6)

            // ── Likes ────────────────────────────────────────────────────────
            Text("1,021 likes")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PaintedSurfaces.instagramInk)
                .padding(.horizontal, 11)
                .padding(.bottom, 5)

            // ── Caption + hashtags ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                if caption.isEmpty && hashtagLine.isEmpty {
                    Text("Caption will appear here…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PaintedSurfaces.instagramCaptionPlaceholder)
                        .italic()
                } else {
                    if !caption.isEmpty {
                        (Text("dwphotony ").font(.system(size: 12.5, weight: .semibold))
                         + Text(caption).font(.system(size: 12.5)))
                            .foregroundStyle(PaintedSurfaces.instagramInk)
                            .lineLimit(4)
                    }
                    if !hashtagLine.isEmpty {
                        Text(hashtagLine)
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.instagramLink)
                            .lineLimit(2)
                    }
                }

                // View all comments
                Text("View all comments")
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.instagramCommentsLine)

                // Timestamp
                Text(dayLabel.uppercased())
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(PaintedSurfaces.instagramDate)
                    .kerning(0.3)
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 12)
        }
        .frame(width: cardWidth)
        .background(PaintedSurfaces.instagramCard)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(PaintedSurfaces.instagramCardEdge, lineWidth: 0.5)
        )
        .shadow(color: PaintedSurfaces.instagramCardShadow, radius: 8, x: 0, y: 2)
        .task(id: displayedPhotoURL) {
            guard let url = displayedPhotoURL else { return }
            // Keep the previous image on screen while loading the next so
            // carousel swaps don't flash a placeholder (and don't reflow the
            // left column via a transient square frame).
            if let loaded = await ImageLoad.read(url).image {
                photo = loaded
            }
        }
    }
}
struct CarouselArrow: View {
    let systemName: String
    /// What pressing it does, said as a person would: "Previous photo". An
    /// arrow glyph with no name is announced as nothing but "button" (#465).
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PaintedSurfaces.instagramGlyph)
                .frame(width: 26, height: 26)
                .background(Circle().fill(PaintedSurfaces.instagramOverlayButton))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
