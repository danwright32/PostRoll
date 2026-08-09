import Foundation
import PDFKit

/// The Vision text layer baked into the program PDF, read back for #209.
///
/// `ProgramPDFBuilder.drawTextLayer` runs Apple Vision over every page at full
/// native resolution at upload time and draws the strings invisibly into the
/// PDF. That layer is a character-level authority for SPELLING: on the real
/// BLUDLINE program it holds "Safa @safa.wav" verbatim and correct, which is the
/// exact character Claude got wrong. The right answer was already on the
/// machine, on device, free, in a file that already existed.
///
/// This reads it back so `postroll.ai.flag_issues` can cross-check every
/// performer name and handle against it. Vision is the better speller, not the
/// better reader, so a mismatch becomes a review flag rather than a silent
/// correction: the Vision reading order is scrambled across columns and cannot
/// say who is a soloist and who is a composer.
enum VisionTextLayer {

    /// Why the text layer cannot be used, in the caller's terms.
    ///
    /// Each case is distinct because they need different words in front of Dan.
    /// Collapsing them into one "unavailable" would tell him something is wrong
    /// while withholding the only part that says what to do about it.
    enum Unavailable: Equatable {
        /// No PDF has been built for this event yet.
        case notBuiltYet
        /// The event points at a PDF that is not on disk.
        case missingOnDisk
        /// The pages changed after the bake, so the layer describes a different
        /// program from the one that was just read.
        case stale
        /// The PDF is there and current, but carries no recognised text. Either
        /// the bake is still running or Vision found nothing on the pages.
        case noTextRecognised
    }

    enum Availability: Equatable {
        case ready(String)
        case unavailable(Unavailable)
    }

    /// Whether the layer can be trusted, given the event and what was read back.
    ///
    /// Split from the PDFKit read so the rule is testable without a PDF on disk:
    /// the decision is the part that gets this wrong, not the file access.
    static func availability(
        pdfPath: URL?,
        pdfExists: Bool,
        currentPages: [URL],
        bakedFingerprint: String?,
        extractedText: String?
    ) -> Availability {
        guard let pdfPath, !pdfPath.path.isEmpty else { return .unavailable(.notBuiltYet) }
        guard pdfExists else { return .unavailable(.missingOnDisk) }
        guard bakedFingerprint == ProgramPDFBuilder.fingerprint(of: currentPages) else {
            return .unavailable(.stale)
        }
        guard let text = extractedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.noTextRecognised)
        }
        return .ready(text)
    }

    /// Read the invisible text layer back out of the PDF.
    ///
    /// Returns nil rather than an empty string when the document cannot be
    /// opened at all, so `availability` can tell "unreadable" apart from
    /// "readable but carrying nothing".
    static func extract(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.string
    }

    /// Convenience over the two above for a whole event.
    static func availability(for event: Event, fileManager fm: FileManager = .default) -> Availability {
        guard let pdf = event.programPDFPath else { return .unavailable(.notBuiltYet) }
        let exists = fm.fileExists(atPath: pdf.path)
        return availability(
            pdfPath: pdf,
            pdfExists: exists,
            currentPages: event.programImagePaths,
            bakedFingerprint: event.programPDFFingerprint,
            extractedText: exists ? extract(from: pdf) : nil)
    }
}

extension VisionTextLayer.Unavailable {
    /// What to tell Dan. Each says what happened AND what it means for the
    /// spelling check, because a warning that only names a state leaves him to
    /// work out whether it mattered.
    var explanation: String {
        switch self {
        case .notBuiltYet:
            return "The searchable program PDF has not been built yet, so names could not be "
                 + "checked against the program's own text. Re-upload the program to build it."
        case .missingOnDisk:
            return "The searchable program PDF is missing from disk, so names could not be "
                 + "checked against the program's own text. Re-upload the program to rebuild it."
        case .stale:
            return "The program pages changed after the searchable PDF was built, so its text "
                 + "describes a different program and was not used to check spelling."
        case .noTextRecognised:
            return "The searchable program PDF carries no recognised text, so names could not "
                 + "be checked against it. Its text layer may still be building."
        }
    }
}
