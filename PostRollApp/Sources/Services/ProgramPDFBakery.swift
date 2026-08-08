import Foundation
import Observation

/// Owns baking an event's program pages into one searchable PDF.
///
/// App-scoped rather than owned by a view, for three reasons the old
/// fire-and-forget `Task.detached` in ProgramUploadView couldn't cover (#80):
///
/// - **A failure was invisible.** `try?` dropped the error, `programPDFPath`
///   stayed nil, and nothing said so.
/// - **It could run twice.** Nothing stopped a second bake starting while one
///   was in flight, so two writers could land on the same file.
/// - **The page scans were deleted on a separate schedule.** Confirming the OCR
///   review threw them away whether or not the PDF they were replaced by
///   existed. Here the delete is something the bake itself does, after the
///   written PDF has been verified, so the order can't come apart.
@MainActor
@Observable
final class ProgramPDFBakery {
    static let shared = ProgramPDFBakery()

    private(set) var baking: Set<UUID> = []
    /// Last bake failure per event, kept until a later bake succeeds so the
    /// generation screen can show it rather than silently offering nothing.
    private(set) var failures: [UUID: String] = [:]

    func isBaking(_ eventID: UUID) -> Bool { baking.contains(eventID) }
    func failure(for eventID: UUID) -> String? { failures[eventID] }

    /// Bakes `event`'s program pages, then writes the PDF path and the page
    /// fingerprint back through `appState`.
    ///
    /// A call while a bake for the same event is already in flight is a no-op:
    /// the pending one is doing the same work against the same destination.
    ///
    /// `deletingScansOnSuccess` runs the page-scan cleanup only after the PDF
    /// has been written AND verified to be on disk, so the program cannot be
    /// destroyed before its replacement exists.
    func bake(event: Event, appState: AppState, deletingScansOnSuccess: Bool = false) {
        let pages = event.programImagePaths
        guard !pages.isEmpty, !baking.contains(event.id) else { return }
        let eventID = event.id
        let dest = AppPaths.programPDFFile(eventID: eventID)
        let fingerprint = ProgramPDFBuilder.fingerprint(of: pages)

        baking.insert(eventID)
        Task.detached(priority: .utility) {
            let outcome: Result<URL, Error>
            do {
                outcome = .success(try ProgramPDFBuilder.writeVerifiedPDF(from: pages, to: dest))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.baking.remove(eventID)
                switch outcome {
                case .failure(let error):
                    // Loud, not silent: without this the program simply stopped
                    // existing and the download button vanished.
                    self.failures[eventID] = error.localizedDescription
                    NSLog("ProgramPDFBakery: bake failed for \(eventID): \(error)")
                case .success(let url):
                    self.failures.removeValue(forKey: eventID)
                    // Live read: the user may have edited the event while this ran.
                    guard var live = appState.events.first(where: { $0.id == eventID }) else { return }
                    live.programPDFPath = url
                    live.programPDFFingerprint = fingerprint
                    if deletingScansOnSuccess {
                        ProgramImageCleanup.delete(urls: pages)
                        // Only the pages this bake actually consumed: the user
                        // may have added one since, and it has no replacement.
                        live.programImagePaths = live.programImagePaths.filter { !pages.contains($0) }
                    }
                    appState.updateEvent(live)
                }
            }
        }
    }
}
