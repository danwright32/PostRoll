import Foundation

/// Whether an event's program page scans can be thrown away yet.
///
/// The scans are the only copies of the program that exist (the Salesforce
/// sites they come from block re-download), and the baked, searchable PDF is
/// what replaces them. Confirming the OCR review used to delete them
/// unconditionally, so a bake that had failed silently, or one that was still
/// running, took the program with it and the download button simply vanished
/// (#80).
///
/// Nothing good is destroyed before its replacement is verified to exist: the
/// PDF must be recorded, present on disk, AND baked from the page set that is
/// there now.
enum ProgramScanRetention {

    enum KeepReason: String, CaseIterable, Equatable {
        /// The bake hasn't produced a path yet: either still running or it
        /// failed without saying so.
        case pdfNotBuiltYet
        /// A path was recorded but the file isn't there.
        case pdfMissingOnDisk
        /// The PDF was baked from a different set of pages than the current one.
        case pdfStale

        /// What to tell the user. Distinct causes get distinct messages.
        var message: String {
            switch self {
            case .pdfNotBuiltYet:
                return "The searchable program PDF hasn't finished baking, so the page scans are being kept. They'll clear once it's done."
            case .pdfMissingOnDisk:
                return "The searchable program PDF is recorded but missing from disk, so the page scans are being kept and the PDF is being rebuilt."
            case .pdfStale:
                return "The searchable program PDF was built from a different set of pages, so the page scans are being kept and the PDF is being rebuilt."
            }
        }
    }

    enum Decision: Equatable {
        case deleteScans
        case keepScans(reason: KeepReason)
        case nothingToDelete
    }

    static func decide(for event: Event, fileManager fm: FileManager = .default) -> Decision {
        let pages = event.programImagePaths
        guard !pages.isEmpty else { return .nothingToDelete }
        guard let pdf = event.programPDFPath else { return .keepScans(reason: .pdfNotBuiltYet) }
        guard fm.fileExists(atPath: pdf.path) else { return .keepScans(reason: .pdfMissingOnDisk) }
        guard event.programPDFFingerprint == ProgramPDFBuilder.fingerprint(of: pages) else {
            return .keepScans(reason: .pdfStale)
        }
        return .deleteScans
    }
}
