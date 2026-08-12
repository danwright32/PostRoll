import Foundation

/// Turning an uploaded program into the pages an event holds.
///
/// Program OCR reads `event.programImagePaths`, and nothing downstream can tell
/// a list that is short because a page failed from a program that genuinely has
/// that many pages. So a PDF whose page 3 never became an image was OCR'd as
/// though it only ever had the others, and the performers and works printed on
/// it were absent from the captions, the blog and the searchable PDF with no
/// error anywhere (#368).
///
/// Two things follow, and they are the whole of this file:
///
/// - `ProgramPDFBuilder.rasterise` returns a `Rasterisation`, carrying every
///   page that did not make it beside the ones that did, rather than a list the
///   caller has no way to check.
/// - An upload that did not come in whole contributes NOTHING. Dan is told
///   which page is missing and why, and can still take the readable pages, but
///   only by choosing to: a partial program never becomes the program by
///   default.
enum ProgramImport {

    /// Why one page, or one whole file, never reached disk. Each cause reads
    /// differently because each calls for a different response: a PDF that will
    /// not open wants re-exporting, a page that would not save wants disk space
    /// (L11).
    enum Failure: Equatable, Sendable {
        /// The file could not be opened as a PDF, or carried no pages at all.
        case unreadableDocument
        /// PDFKit had no page at this 1-based index.
        case missingPage(Int)
        /// The page could not be turned into a PNG.
        case couldNotRenderPage(Int)
        /// The page's PNG could not be written to disk.
        case couldNotWritePage(Int, reason: String)
        /// An uploaded image could not be copied into the program folder.
        case couldNotStoreFile(reason: String)

        /// The 1-based page this is about, when it is about a single page.
        var page: Int? {
            switch self {
            case .missingPage(let page), .couldNotRenderPage(let page):
                return page
            case .couldNotWritePage(let page, _):
                return page
            case .unreadableDocument, .couldNotStoreFile:
                return nil
            }
        }

        /// What went wrong, phrased for Dan rather than for a log.
        var message: String {
            switch self {
            case .unreadableDocument:
                return "The file wouldn't open as a PDF, or it has no pages in it."
            case .missingPage(let page):
                return "Page \(page) couldn't be read out of the PDF."
            case .couldNotRenderPage(let page):
                return "Page \(page) couldn't be turned into an image."
            case .couldNotWritePage(let page, let reason):
                return "Page \(page) couldn't be saved: \(reason)"
            case .couldNotStoreFile(let reason):
                return "The file couldn't be copied into PostRoll's program folder: \(reason)"
            }
        }
    }

    /// One upload's outcome: the pages that genuinely reached disk, and every
    /// page that did not. A caller reading only `pages` is reading a program
    /// that may be missing some, which is the defect this type exists to close.
    struct Rasterisation: Sendable {
        var pages: [URL] = []
        var failures: [Failure] = []

        /// True only when every page of the upload became a file on disk.
        var isComplete: Bool { failures.isEmpty }
    }

    /// One uploaded file, ready to be rasterised or already copied.
    struct Upload: Sendable {
        let source: URL
        let result: Rasterisation

        init(source: URL, result: Rasterisation) {
            self.source = source
            self.result = result
        }
    }

    /// An upload that did not come in whole, held so it can be shown and, if
    /// Dan decides the missing page does not matter, accepted deliberately.
    struct Incomplete: Identifiable, Sendable {
        let id = UUID()
        let fileName: String
        /// The pages that did reach disk. Kept rather than deleted: they are
        /// what "import the pages that worked" imports, and OrphanedMediaCleanup
        /// reclaims them if Dan never does.
        let pagesThatWorked: [URL]
        let failures: [Failure]

        init(fileName: String, pagesThatWorked: [URL], failures: [Failure]) {
            self.fileName = fileName
            self.pagesThatWorked = pagesThatWorked
            self.failures = failures
        }

        /// Names the file, every page that is missing and why, and says plainly
        /// that nothing was imported. A banner that only said "some pages
        /// failed" would leave Dan unable to tell whether what he is looking at
        /// is the program.
        var message: String {
            let causes = failures.map(\.message).joined(separator: " ")
            let outcome: String
            if pagesThatWorked.isEmpty {
                outcome = "Nothing from this file was imported."
            } else {
                let count = pagesThatWorked.count
                outcome = "None of the \(count) page\(count == 1 ? "" : "s") that did come through "
                    + "were imported, because OCR would read them as the whole program."
            }
            return "\(fileName) didn't come in whole. \(causes) \(outcome)"
        }
    }

    /// What a batch of uploads contributes to the event, and what has to be
    /// reported instead of contributed.
    struct Plan {
        var pagesToAdd: [URL] = []
        var incomplete: [Incomplete] = []
    }

    /// Splits a batch into the pages that may be added and the uploads that may
    /// not. Order is the order the files were given, so the program reads the
    /// way it was uploaded.
    static func plan(for uploads: [Upload]) -> Plan {
        var plan = Plan()
        var seen: Set<URL> = []
        for upload in uploads {
            guard upload.result.isComplete else {
                plan.incomplete.append(Incomplete(
                    fileName: upload.source.lastPathComponent,
                    pagesThatWorked: upload.result.pages,
                    failures: upload.result.failures
                ))
                continue
            }
            for page in upload.result.pages where !seen.contains(page) {
                seen.insert(page)
                plan.pagesToAdd.append(page)
            }
        }
        return plan
    }
}
