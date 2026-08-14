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

    /// One page of the gap: which page of the programme it is, and where that
    /// page is right now (#558).
    ///
    /// `number` is 1-based, and nil when nothing could place the page: the
    /// programme no longer runs that far, or a path stored before positions
    /// existed matches nothing in it. Nil is carried rather than papered over,
    /// because a page with no position must not be numbered by guesswork and
    /// then struck off in place of a real one.
    struct Page: Equatable {
        let number: Int?
        let path: String
    }

    /// The pages to send, or nil when there is no gap to close.
    ///
    /// Resolved against the programme as it is NOW rather than trusted as
    /// stored. The stored paths were exactly what the earlier run named, which
    /// held only while nothing moved them, and `rebasePaths` exists in this app
    /// precisely because things do move: the gap then named files nothing could
    /// find, every page in it read as missing, and the only route left was
    /// paying to read the whole programme again (L15).
    ///
    /// Two ways in, because gaps recorded before #558 carry no positions at
    /// all. Those are placed by matching what was stored against the current
    /// programme, exact path first and then filename, so an old gap is
    /// recovered rather than left unresolvable. A page nothing can place keeps
    /// what was stored and goes on to be refused honestly.
    static func pages(for result: OCRResult, in programme: [URL]) -> [Page]? {
        guard !result.unreadPages.isEmpty else { return nil }
        let current = programme.map(\.path)
        // Paired by index or not paired at all. Lists of different lengths
        // would put one page's number against another page's path, which is
        // worse than carrying no numbers (L83).
        let recorded = result.unreadPageNumbers.count == result.unreadPages.count
            ? result.unreadPageNumbers : []

        return result.unreadPages.enumerated().map { index, stored in
            let number = recorded.isEmpty ? 0 : recorded[index]
            if number >= 1, number <= current.count {
                return Page(number: number, path: current[number - 1])
            }
            if let found = place(stored, in: current) {
                return Page(number: found + 1, path: current[found])
            }
            return Page(number: nil, path: stored)
        }
    }

    /// A page this rescan can actually read: where it sits in the programme as
    /// it is now, and where that page is on disk.
    ///
    /// The position is not optional, unlike `Page`'s. Python needs one number
    /// per image and there is no value meaning "unknown" it could be padded
    /// with: `NO_PAGE_NUMBER` is zero, which the merge reads as every page of
    /// unknown position at once (#576). So a page with no position is never
    /// sent, and the type is what says so rather than a check somewhere that
    /// could be forgotten.
    struct PlacedPage: Equatable {
        let number: Int
        let path: String
    }

    /// What a rescan of this gap would actually do: which pages go, which stay,
    /// and what has to be said about either.
    ///
    /// `refusal` and `sendable` cannot disagree: a refusal always leaves nothing
    /// to send, so a caller that reads one and not the other cannot pay for a
    /// run this has already refused.
    struct Plan: Equatable {
        /// The pages to send, each with its position. Empty when nothing runs.
        let sendable: [PlacedPage]
        /// The pages nothing could place, left in the gap exactly as they were.
        let unplaceable: [Page]
        /// Why nothing can run at all, or nil when it can.
        let refusal: String?
        /// What this run will not read even though it is going ahead, or nil.
        let note: String?
    }

    /// Which pages of the gap this rescan can read, and what to say about the
    /// rest (#575).
    ///
    /// It used to be all or none: the positions were sent only when every page
    /// in the gap had one, so a single unplaceable page (the programme
    /// re-uploaded shorter, a stored path matching nothing) dropped the
    /// positions for the whole batch and the merge fell back to matching on
    /// file paths for pages whose position was known perfectly well. That is
    /// the matching #558 replaced, switched off for the good pages by one odd
    /// one, and the fallback was chosen without measuring how often it fires
    /// (L93).
    ///
    /// So the pages that resolved go as their own rescan, with one number per
    /// image and nothing padded, and the pages that did not stay in the gap.
    /// They are named on the way past rather than quietly dropped: a page left
    /// out with no word said would sit in the gap forever while every rescan
    /// appeared to run cleanly (L11, L98).
    static func plan(for pages: [Page]) -> Plan {
        let sendable = pages.compactMap { page in
            page.number.map { PlacedPage(number: $0, path: page.path) }
        }
        let unplaceable = pages.filter { $0.number == nil }
        let cannotPlace = unplaceableSentence(unplaceable.map(\.path))
        // Decided over the pages about to be SENT. Refusing on a page this run
        // is not sending would be the same defect in another form: one page
        // nothing can do anything about stopping the ones that can be read.
        let cannotRead = refusal(forPages: sendable.map(\.path))

        guard !sendable.isEmpty, cannotRead == nil else {
            // Both causes, because a refusal naming one of them leaves the other
            // pages unaccounted for beside a remedy that cannot fix them.
            let both = [cannotRead, cannotPlace].compactMap { $0 }.joined(separator: " ")
            return Plan(sendable: [], unplaceable: unplaceable,
                        refusal: both.isEmpty ? nil : both, note: nil)
        }
        return Plan(sendable: sendable, unplaceable: unplaceable,
                    refusal: nil, note: cannotPlace)
    }

    /// The pages the programme as it stands has no place for.
    ///
    /// Worded apart from the moved and denied sentences because it is a third
    /// fault with a third cause: the page has not gone anywhere, the programme
    /// is what changed under it, and re-uploading is the only thing that can
    /// put it back in a position the merge can key to.
    private static func unplaceableSentence(_ paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let list = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
                        .joined(separator: ", ")
        return paths.count == 1
            ? "\(list) is not a page of the programme as it stands now, so there "
              + "is no position to read it under and it will not be scanned. It "
              + "stays listed as unread. Upload the programme again if it should "
              + "be part of it."
            : "These pages are not part of the programme as it stands now, so "
              + "there is no position to read them under and they will not be "
              + "scanned: \(list). They stay listed as unread. Upload the "
              + "programme again if they should be part of it."
    }

    /// Where a stored path sits in the programme as it is now, or nil.
    ///
    /// Filename after full path, because a rebase changes the folder and keeps
    /// the name. Every programme image is copied into `AppPaths.programsDir` on
    /// import, so the names within one event's programme are unique and this
    /// cannot pick the wrong page out of two folders.
    private static func place(_ stored: String, in current: [String]) -> Int? {
        if let exact = current.firstIndex(of: stored) { return exact }
        let name = URL(fileURLWithPath: stored).lastPathComponent
        return current.firstIndex { URL(fileURLWithPath: $0).lastPathComponent == name }
    }

    /// Whether a page in the gap can be read now, and if not, why not.
    ///
    /// Three ways it can fail, and only one of them is fixed by uploading
    /// again, so they are kept apart (L11). `FileManager.fileExists` cannot
    /// separate absent from refused: it answers false for a path this process
    /// is DENIED as well as for one that is gone, so a folder macOS has not
    /// granted access to used to report every page inside it as gone. Only the
    /// error from an attempted read tells them apart, which is the same reason
    /// `AnalyticsStore.load` refuses to use `fileExists` either (#557, #439).
    enum PageReadability: Equatable {
        case readable
        /// Not on disk at all. Re-uploading is the only way back.
        case missing
        /// There, and this process is refused. A settings change fixes it, and
        /// re-uploading into the same folder would not.
        case denied
        /// Some third thing went wrong opening it. Neither remedy is known to
        /// apply, so the message says what happened and prescribes nothing
        /// (L11).
        case unreadable(String)
    }

    static func readability(ofPage path: String) -> PageReadability {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            try? handle.close()
            return .readable
        } catch let error as NSError where error.isFileNotFound {
            return .missing
        } catch let error as NSError where error.isPermissionDenied {
            return .denied
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Why this cannot run, or nil when it can.
    ///
    /// A page named in the gap can have been moved or deleted since, or can be
    /// sitting in a folder this app is not allowed to read. Saying so beats
    /// sending Python a path it will fail on, and beats a control that looks
    /// live and cannot work: the code that finds the page unreachable has
    /// already proved the action is impossible, so it refuses here rather than
    /// letting the attempt be made (L67).
    ///
    /// Each cause gets its own sentence, and a gap holding more than one gets
    /// all of them, because a message reporting only one leaves the other pages
    /// unaccounted for while naming a remedy that cannot fix them.
    static func refusal(forPages pages: [String]) -> String? {
        message(for: pages.map { ($0, readability(ofPage: $0)) })
    }

    /// The wording, kept apart from the filesystem so every cause can be worded
    /// and read cold without having to arrange a disk that produces it (L21).
    static func message(for pages: [(path: String, readability: PageReadability)]) -> String? {
        func names(_ keep: (PageReadability) -> Bool) -> [String] {
            pages.filter { keep($0.readability) }
                 .map { URL(fileURLWithPath: $0.path).lastPathComponent }
        }

        let missing = names { $0 == .missing }
        let denied = names { $0 == .denied }
        let broken: [(String, String)] = pages.compactMap { page in
            guard case .unreadable(let reason) = page.readability else { return nil }
            return (URL(fileURLWithPath: page.path).lastPathComponent, reason)
        }

        var sentences: [String] = []
        if !missing.isEmpty { sentences.append(movedSentence(missing)) }
        if !denied.isEmpty { sentences.append(deniedSentence(denied)) }
        sentences.append(contentsOf: broken.map(unreadableSentence))
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func movedSentence(_ names: [String]) -> String {
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) is no longer where it was uploaded from, so it cannot be "
              + "scanned again. Upload the programme again to read it."
            : "These pages are no longer where they were uploaded from, so they "
              + "cannot be scanned again: \(list). Upload the programme again to "
              + "read them."
    }

    /// No settings pane is named here, deliberately.
    ///
    /// Every programme page is copied into `AppPaths.programsDir` on import, so
    /// a refused page is one inside PostRoll's own storage under Application
    /// Support. That is not a location System Settings lists under Privacy &
    /// Security > Files and Folders, which covers Documents, Desktop, Downloads
    /// and removable volumes, so an earlier draft of this sentence sent Dan to
    /// look for a switch that would not be there. A remedy has to name a step
    /// that can actually change the state it is offered for (L111), and the
    /// only thing measured here is the refusal itself.
    private static func deniedSentence(_ names: [String]) -> String {
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) is still there in PostRoll's own program folder, and "
              + "PostRoll was refused when it tried to read it. Nothing was "
              + "scanned. This is a permissions problem, not a missing page."
            : "These pages are still there in PostRoll's own program folder, "
              + "and PostRoll was refused when it tried to read them: \(list). "
              + "Nothing was scanned. This is a permissions problem, not a set "
              + "of missing pages."
    }

    /// No remedy offered, because none was measured. Naming the failure lets
    /// Dan report what actually happened instead of following advice written
    /// for a different fault. Closed through `Sentence` so the reason, which
    /// arrives punctuated or not depending on who wrote it, cannot leave this
    /// running into whatever follows.
    private static func unreadableSentence(name: String, reason: String) -> String {
        "\(name) could not be opened, so it cannot be scanned again. "
            + Sentence.closed(reason)
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
