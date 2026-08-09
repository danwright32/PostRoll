import Foundation

/// Whether the week is safe to export yet (#89).
///
/// The failure this prevents: Dan applies a change to the Thursday reel, which
/// is a multi-minute ffmpeg rebuild, then presses Approve and Export and picks
/// a folder. The export copies the OLD mp4, because the new one lands in
/// previews after the export finished. The posting week folder silently holds
/// the version without his edits, and he finds out after posting.
///
/// The bottom bar already hid the button during caption regeneration, graphics
/// generation and edit review, but not during per-day rebuilds, which are the
/// longest running of the four.
enum ExportReadiness {

    /// Why export is not available yet, or nil when it is.
    ///
    /// Returns the reason rather than a bool so the button can be replaced by
    /// something that says what it is waiting for. A control that silently
    /// does nothing, or vanishes with no explanation, reads as broken.
    static func blockedReason(regeneratingDays: Set<DayName>) -> String? {
        guard !regeneratingDays.isEmpty else { return nil }
        let names = DayName.allCases
            .filter { regeneratingDays.contains($0) }
            .map(\.displayName)
        switch names.count {
        case 1:  return "Waiting for the \(names[0]) rebuild"
        case 2:  return "Waiting for the \(names[0]) and \(names[1]) rebuilds"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "Waiting for the \(head) and \(names.last!) rebuilds"
        }
    }

    static func canExport(regeneratingDays: Set<DayName>) -> Bool {
        blockedReason(regeneratingDays: regeneratingDays) == nil
    }
}
