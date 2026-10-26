import Foundation

/// What a flag on the program review screen can do to the entry it is about,
/// and what that does to the other flags (#1573).
///
/// Flags name their entry by POSITION (`performers[10].name`), so removing or
/// restoring an entry moves every later flag in that list, and an action taken
/// through a stale position lands on somebody else (L237). Every route that
/// removes or restores an entry goes through here, and an action first checks
/// the entry still holds the value the flag shows.
///
/// Pure, so it can be asserted without the screen behind it.
enum OCRFlagEdits {

    /// Why an action was refused. Nothing is changed in any of these cases.
    enum Refusal: Error, Equatable {
        /// The flag is about a field outside any list, so there is no entry.
        case notInAList
        /// The position no longer exists in the program data.
        case missing
        /// The position holds a different value now, so it is a different entry.
        case entryChanged(now: String)

        /// `field` is the name of the flagged field, e.g. "name".
        func message(field: String) -> String {
            switch self {
            case .notInAList:
                return "This isn't an entry in a list, so it can't be removed. Edit the value or describe the correction instead."
            case .missing:
                return "This entry is no longer in the program data, so nothing was changed."
            case .entryChanged(let now):
                return "This entry's \(field) is now \u{201C}\(now)\u{201D}, not what Claude flagged, so nothing was changed. Check it in its section below."
            }
        }
    }

    /// The list element a path lands inside: the innermost one, so a flag on
    /// one movement of a work is about that movement, not the whole work.
    static func entry(of path: [FlagPathSegment]) -> (list: [FlagPathSegment], index: Int)? {
        guard let last = path.lastIndex(where: {
            if case .index = $0 { return true } else { return false }
        }), case .index(let i) = path[last] else { return nil }
        return (Array(path[..<last]), i)
    }

    /// What the entry is called, e.g. "performer", or nil when there is none.
    static func entryNoun(for path: [FlagPathSegment]) -> String? {
        guard let entry = entry(of: path) else { return nil }
        switch fieldName(of: entry.list) {
        case "performers": return "performer"
        // "Work" is what the Program section and its undo call a piece.
        case "pieces":     return "work"
        case "scenes":     return "scene"
        case "movements":  return "movement"
        default:           return "entry"
        }
    }

    /// The words on the remove button, or nil when the flag has no entry.
    static func removeLabel(for path: [FlagPathSegment]) -> String? {
        entryNoun(for: path).map { "Remove \($0)" }
    }

    /// Last `key` segment of a path, e.g. "name" or "composer".
    static func fieldName(of path: [FlagPathSegment]) -> String {
        for seg in path.reversed() {
            if case .key(let s) = seg { return s }
        }
        return "value"
    }

    /// Nil when the flag's position still holds the value it shows, else why not.
    ///
    /// Only a text field can be checked: a flag on a whole entry carries it as
    /// JSON Claude wrote, which cannot be compared reliably, so that position is
    /// trusted. Every in app removal moves flags, so it goes stale only through
    /// a describe-the-correction rewrite. Case and surrounding space are
    /// ignored because Claude writes `current_value` itself (L161).
    static func stillHolds(_ flag: OCRFlag, in ocr: OCRResult) -> Refusal? {
        guard let tree = tree(of: ocr), let node = node(at: flag.fieldPath, in: tree) else {
            return .missing
        }
        guard let text = node as? String else { return nil }
        if normalised(text) == normalised(flag.currentValue) { return nil }
        return .entryChanged(now: text)
    }

    /// What a remove took out, enough to put it back.
    struct Removal {
        let list: [FlagPathSegment]
        let index: Int
        /// The removed element in the result's JSON form.
        let element: Any
        /// The flags the remove resolved, and only those, so an undo does not
        /// reopen one Dan had already settled.
        let resolvedIDs: Set<OCRFlag.ID>
    }

    /// Remove the entry `flag` is about, resolve every flag on that entry, and
    /// move the later flags in the same list down one so they keep their entry.
    /// Fails, having changed nothing, when it cannot.
    static func removeEntry(for flag: OCRFlag, ocr: inout OCRResult,
                            flags: inout [OCRFlag]) -> Result<Removal, Refusal> {
        guard let entry = entry(of: flag.fieldPath) else { return .failure(.notInAList) }
        if let refusal = stillHolds(flag, in: ocr) { return .failure(refusal) }
        guard var tree = tree(of: ocr),
              let element = node(at: entry.list + [.index(entry.index)], in: tree),
              edit(list: entry.list, in: &tree, { $0.remove(at: entry.index) }),
              let updated = result(from: tree) else {
            return .failure(.missing)
        }
        let moved = Self.flags(flags, afterRemoving: entry.index, from: entry.list)
        let resolvedIDs = newlyResolved(from: flags, to: moved)
        ocr = updated
        flags = moved
        return .success(Removal(list: entry.list, index: entry.index,
                                element: element, resolvedIDs: resolvedIDs))
    }

    /// Undo a remove: the entry goes back at its position, the flags it
    /// resolved reopen, and the later flags move back up one.
    static func restore(_ removal: Removal, ocr: inout OCRResult, flags: inout [OCRFlag]) {
        guard var tree = tree(of: ocr),
              edit(list: removal.list, in: &tree, {
                  $0.insert(removal.element, at: min(removal.index, $0.count))
              }),
              let updated = result(from: tree) else { return }
        ocr = updated
        flags = Self.flags(flags, afterInserting: removal.index, into: removal.list,
                           reopening: removal.resolvedIDs)
    }

    /// The flags after the element at `from` was moved to final index `to` of
    /// the list at `listPath` (a drag reorder): each open flag follows its entry.
    static func flags(_ flags: [OCRFlag], afterMoving from: Int, to: Int,
                      in listPath: [FlagPathSegment]) -> [OCRFlag] {
        flags.map { flag in
            guard !flag.resolved, let i = position(of: flag, in: listPath) else { return flag }
            let landed: Int
            if i == from {
                landed = to
            } else {
                // Taken out of the list, then put back at `to`.
                let closed = i > from ? i - 1 : i
                landed = closed >= to ? closed + 1 : closed
            }
            var moved = flag
            moved.fieldPath[listPath.count] = .index(landed)
            return moved
        }
    }

    /// Where an element ends up after `move(fromOffsets: [from], toOffset:)`,
    /// whose offset counts the gap before the moved element is taken out.
    static func finalIndex(movingFrom from: Int, toOffset offset: Int) -> Int {
        offset > from ? offset - 1 : offset
    }

    /// The flags open in `before` and resolved in `after`: what a removal
    /// settled, so its undo can reopen exactly those.
    static func newlyResolved(from before: [OCRFlag], to after: [OCRFlag]) -> Set<OCRFlag.ID> {
        let wasOpen = Set(before.filter { !$0.resolved }.map(\.id))
        return Set(after.filter { $0.resolved && wasOpen.contains($0.id) }.map(\.id))
    }

    /// The flags after element `index` of the list at `listPath` was removed.
    ///
    /// Open flags on that element are resolved, as there is nothing left for
    /// them to be about; open flags on later elements move down one. Resolved
    /// flags keep the position they were settled at, since nothing acts on them.
    static func flags(_ flags: [OCRFlag], afterRemoving index: Int,
                      from listPath: [FlagPathSegment]) -> [OCRFlag] {
        flags.map { flag in
            guard !flag.resolved, let i = position(of: flag, in: listPath) else { return flag }
            var moved = flag
            if i == index { moved.resolved = true }
            else if i > index { moved.fieldPath[listPath.count] = .index(i - 1) }
            return moved
        }
    }

    /// The flags after an element was put back at `index` of the list at
    /// `listPath` (an undone delete): open flags at or after it move up one,
    /// then the flags its removal resolved, `reopening`, are opened again. They
    /// kept the removed element's position, which is where it has gone back.
    static func flags(_ flags: [OCRFlag], afterInserting index: Int,
                      into listPath: [FlagPathSegment],
                      reopening: Set<OCRFlag.ID> = []) -> [OCRFlag] {
        flags.map { flag in
            var moved = flag
            if !flag.resolved, let i = position(of: flag, in: listPath), i >= index {
                moved.fieldPath[listPath.count] = .index(i + 1)
            }
            if reopening.contains(flag.id) { moved.resolved = false }
            return moved
        }
    }

    /// The node at `path` in the JSON form of a result, or nil.
    ///
    /// Shared with the review screen's check for a plain text field, so both
    /// walk the result the same way.
    static func node(at path: [FlagPathSegment], in tree: Any) -> Any? {
        var node: Any = tree
        for seg in path {
            switch seg {
            case .key(let k):
                guard let dict = node as? [String: Any], let next = dict[k] else { return nil }
                node = next
            case .index(let i):
                guard let arr = node as? [Any], i >= 0, i < arr.count else { return nil }
                node = arr[i]
            }
        }
        return node
    }

    static func tree(of ocr: OCRResult) -> Any? {
        guard let data = try? JSONEncoder().encode(ocr) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - Private

    /// Where in `listPath` the flag sits, when its path runs through that list.
    private static func position(of flag: OCRFlag, in listPath: [FlagPathSegment]) -> Int? {
        let path = flag.fieldPath
        guard path.count > listPath.count, Array(path.prefix(listPath.count)) == listPath,
              case .index(let i) = path[listPath.count] else { return nil }
        return i
    }

    private static func normalised(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func result(from tree: Any) -> OCRResult? {
        guard let data = try? JSONSerialization.data(withJSONObject: tree) else { return nil }
        return try? JSONDecoder().decode(OCRResult.self, from: data)
    }

    /// Run `change` on the list at `path` inside `tree`. False, with `tree`
    /// unchanged, when the path does not lead to a list.
    private static func edit(list path: [FlagPathSegment], in tree: inout Any,
                             _ change: (inout [Any]) -> Void) -> Bool {
        guard let head = path.first else {
            guard var arr = tree as? [Any] else { return false }
            change(&arr)
            tree = arr
            return true
        }
        let tail = Array(path.dropFirst())
        switch head {
        case .key(let k):
            guard var dict = tree as? [String: Any], var child = dict[k],
                  edit(list: tail, in: &child, change) else { return false }
            dict[k] = child
            tree = dict
        case .index(let i):
            guard var arr = tree as? [Any], i >= 0, i < arr.count else { return false }
            var child = arr[i]
            guard edit(list: tail, in: &child, change) else { return false }
            arr[i] = child
            tree = arr
        }
        return true
    }
}
