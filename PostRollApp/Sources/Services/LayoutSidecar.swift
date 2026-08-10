import Foundation

/// Where a rendered preview's layout sidecar lives (#267).
///
/// The collage and the Thursday reel strip each write a JSON file beside their
/// PNG recording the cell rectangles, so the crop editor can draw its controls
/// over the right parts of the image and the export compositor can honour a
/// dragged divider.
///
/// Python writes it and this side reads it, from three screens and the export
/// path. The name used to be rebuilt independently in five places, one of them
/// a hardcoded `reel_preview_layout.json` literal, with nothing forcing them to
/// agree. The first one changed would have broken the editor or the export on
/// one screen only while the others kept working, which is the hardest version
/// of this to notice.
///
/// `postroll/media/layout_sidecar.py` is the writing half.
/// `tests/fixtures/layout_sidecar.json` is the contract both satisfy.
enum LayoutSidecar {

    /// Appended to the preview's name, without its extension.
    static let suffix = "_layout.json"

    /// The sidecar that belongs to `preview`, in the same directory.
    static func url(for preview: URL) -> URL {
        preview
            .deletingLastPathComponent()
            .appendingPathComponent(preview.deletingPathExtension().lastPathComponent + suffix)
    }
}
