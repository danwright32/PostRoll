import SwiftUI

/// The parts of photo assignment that only say things, pulled out of
/// `PhotoAssignmentView` so they can be rendered and measured outside the running
/// app (#396).
///
/// The day sections stay in the screen: they are drop targets writing into
/// bindings. What comes out here is the column of notices at the top and the bar
/// at the bottom, including the missing-media banner, which needed a photo to
/// actually go missing off disk before anyone could look at it.

/// What photo assignment says before the days.
struct PhotoAssignmentNotices: View {
    /// The result of the last folder import, worded by `ImportFailureText` or by
    /// the import itself. nil while nothing has been imported this visit.
    var importResult: String? = nil
    var importFailed: Bool = false
    /// Photos this event references whose files are gone.
    var missingPhotoCount: Int = 0
    /// Named standalone files, so the banner points at the control to fix rather
    /// than only counting files.
    var missingStandaloneNames: [String] = []
    var onLocateMissing: () -> Void = {}
    var onRemoveMissing: () -> Void = {}
    var onImportFolder: () -> Void = {}

    private var hasMissingMedia: Bool {
        missingPhotoCount > 0 || !missingStandaloneNames.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            BrandBanner(
                icon: "rectangle.3.group",
                message: "Drop photos into each posting day, or import a whole folder organized by day subfolders (named sunday to friday or day 1 to day 6). Wednesday and Thursday show a crop button on each photo, and Wednesday photos also have a tag button to note who's in each carousel slide."
            )

            if let importResult {
                BrandBanner(
                    icon: importFailed ? "exclamationmark.circle" : "checkmark.circle",
                    message: importResult,
                    style: importFailed ? .error : .info
                )
            }

            if hasMissingMedia {
                MissingPhotosBanner(
                    photoCount: missingPhotoCount,
                    standaloneNames: missingStandaloneNames,
                    onLocate: onLocateMissing,
                    onRemove: onRemoveMissing
                )
            }

            HStack {
                Spacer()
                Button("Import from folder…", action: onImportFolder)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
            }
        }
    }
}

/// The bar that ends photo assignment.
struct PhotoAssignmentContinueBar: View {
    let totalPhotos: Int
    var onContinue: () -> Void = {}

    /// One predicate for the button's enabled state and the sentence explaining
    /// it, so a disabled button can never sit there with nothing said (L109).
    var canContinue: Bool { totalPhotos > 0 }

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.sm) {
            if !canContinue {
                Text("Add photos to at least one day to continue.")
                    .font(.light(11))
                    .foregroundStyle(Color.warmMid)
            }
            HStack {
                Spacer()
                Button("Continue to Generation", action: onContinue)
                    .buttonStyle(BrandButtonStyle())
                    .disabled(!canContinue)
            }
        }
        .padding(Spacing.xl)
    }
}

/// Shown when an event references photos whose files are gone, offering to drop
/// the dead references in one click.
///
/// Moved out of `PhotoAssignmentView`, where it was file private and therefore
/// impossible to render from anywhere else (#396).
struct MissingPhotosBanner: View {
    let photoCount: Int
    /// Named standalone files (for example "Tuesday B&W photo").
    var standaloneNames: [String] = []
    let onLocate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.roseGold)
            Text(MissingMediaBannerText.message(photoCount: photoCount,
                                                standaloneNames: standaloneNames))
                .font(.system(size: 11))
                .foregroundStyle(Color.warmDark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Locate…", action: onLocate)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.roseGold)
            Text("·").foregroundStyle(Color.warmMid.opacity(0.5))
            Button("Remove missing", action: onRemove)
                .buttonStyle(BrandOutlineButtonStyle())
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.roseGold.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.roseGold.opacity(0.25), lineWidth: 0.5))
        )
    }
}
