import Foundation

/// How the export screen draws an `ExportFolderStatus`, or nil when it draws
/// nothing at all.
///
/// Both the style and the icon come from the status's own `attention` rather
/// than being written at the call site, which is how the absent-folder case
/// came to be drawn in the fault style while saying nothing was wrong (#1110).
/// A screen that spells the severity separately from the thing that decides it
/// is a screen those two can disagree on (L41).
struct ExportFolderBanner: Equatable {
    let icon: String
    let style: BrandBannerStyle

    static func of(_ status: ExportFolderStatus) -> ExportFolderBanner? {
        switch status.attention {
        case .none:
            return nil
        // A folder the app has merely lost track of gets the folder icon, not
        // the warning triangle: the icon is read before the words, so a
        // triangle would go on saying "fault" after the sentence stopped.
        case .informational:
            return ExportFolderBanner(icon: "folder.badge.questionmark", style: .info)
        case .warning:
            return ExportFolderBanner(icon: "exclamationmark.triangle", style: .warning)
        }
    }
}
