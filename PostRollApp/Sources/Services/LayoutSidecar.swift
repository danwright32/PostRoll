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

    /// What a sidecar holds: the cells, and which collage design made them.
    ///
    /// `version` is nil for a sidecar written before the stamp existed (#160),
    /// which is a bare array. Nil rather than 0: not knowing which design made
    /// something is a different fact from knowing it was the first one.
    struct Contents: Equatable {
        var version: Int?
        var cells: [CollageCell]

        /// Where the branded centre strip SAT in this layout (#970).
        ///
        /// Nil for a reel strip, which has no strip, and for every collage
        /// sidecar written before this was recorded. Nil means "not recorded"
        /// rather than "no strip": the checks that read it decline to judge the
        /// band rather than inventing one, because a made up band would refuse
        /// layouts for a position nobody chose.
        var strip: StripBand?

        /// Whether this collage predates the design this build renders.
        var isStale: Bool { (version ?? 0) < CollageDesign.collageDesignVersion }
    }

    struct StripBand: Equatable, Decodable {
        var y: Int
        var h: Int
    }

    /// Read a sidecar in either shape, tolerating everything already on disk.
    ///
    /// Every collage rendered before the stamp existed has the old bare-array
    /// shape, and treating those as unreadable would blank a day's crop
    /// editing rather than badge it.
    ///
    /// Never throws: a missing or corrupt sidecar means the editor falls back
    /// to the automatic layout, which is what it did before any of this.
    static func read(at url: URL) -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents(version: nil, cells: []) }
        if let cells = try? JSONDecoder().decode([CollageCell].self, from: data) {
            return Contents(version: nil, cells: cells)
        }
        struct Envelope: Decodable {
            var version: Int?
            var cells: [CollageCell]?
            var strip: StripBand?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return Contents(version: nil, cells: [])
        }
        // A band of zero height is not a band. Python omits `strip` entirely
        // where there is none, so a zero here is a malformed file rather than a
        // layout without a strip, and reading it as one would judge every cell
        // against a band with no thickness (L257).
        let band = envelope.strip.flatMap { $0.h > 0 ? $0 : nil }
        return Contents(version: envelope.version, cells: envelope.cells ?? [],
                        strip: band)
    }

    /// The contents of the sidecar belonging to a rendered preview.
    static func read(forPreview preview: URL) -> Contents {
        read(at: url(for: preview))
    }
}
