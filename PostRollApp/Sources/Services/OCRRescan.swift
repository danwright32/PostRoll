import Foundation

/// Scanning only the pages an earlier run could not read (#518).
///
/// A large programme is read in several paid calls of up to ten minutes. When
/// one dies, the pages it had already read are kept and the ones it lost are
/// recorded as a gap, so closing that gap used to mean re-running the whole
/// scan and paying again for every page that was read the first time.
///
/// The decisions live here rather than in the view, so the rule that says
/// whether a rescan is possible and the control that offers it cannot disagree
/// (L109). The merge that folds the answer back into the stored result belongs
/// to Python, beside the merge that already combines batches within one run, so
/// there is no second implementation of it on this side (L16).
enum OCRRescan {

    /// The pages to send, or nil when there is no gap to close.
    ///
    /// Exactly the strings the earlier run named, not basenames and not the
    /// whole programme: the merge matches the answer against these same
    /// strings, so anything else breaks the match without erroring.
    static func pages(for result: OCRResult) -> [String]? {
        result.unreadPages.isEmpty ? nil : result.unreadPages
    }

    /// Why this cannot run, or nil when it can.
    ///
    /// A page named in the gap can have been moved or deleted since. Saying so
    /// beats sending Python a path it will fail on, and beats a control that
    /// looks live and cannot work: the code that finds the file missing has
    /// already proved the action is impossible, so it refuses here rather than
    /// letting the attempt be made (L67).
    static func refusal(forPages pages: [String]) -> String? {
        let gone = pages.filter { !FileManager.default.fileExists(atPath: $0) }
        guard !gone.isEmpty else { return nil }
        let names = gone.map { URL(fileURLWithPath: $0).lastPathComponent }
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) is no longer where it was uploaded from, so it cannot be "
              + "scanned again. Upload the programme again to read it."
            : "These pages are no longer where they were uploaded from, so they "
              + "cannot be scanned again: \(list). Upload the programme again to "
              + "read them."
    }

    /// What the control says.
    ///
    /// It names the amount of work, because "Scan again" sitting beside a
    /// warning about three pages reads as re-running the whole programme, which
    /// is the paid thing this feature exists to avoid (L21, L118).
    static func buttonTitle(pageCount: Int) -> String {
        pageCount == 1 ? "Scan the 1 page that was missed"
                       : "Scan the \(pageCount) pages that were missed"
    }
}
