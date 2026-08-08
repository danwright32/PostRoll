import SwiftUI
import AppKit

/// NSTextView-backed editor with continuous spell checking and grammar checking.
/// Drop-in for SwiftUI's TextEditor where squiggly-underline spell checking is needed.
///
/// Usage:
///   SpellCheckingTextEditor(text: $text)
///       .nsFont(.systemFont(ofSize: 12))
///       .nsTextColor(NSColor(Color.warmDark))
///       .frame(minHeight: 80)
///       .padding(8)
///       .background(...)
struct SpellCheckingTextEditor: NSViewRepresentable {
    @Binding var text: String
    private var font: NSFont = .systemFont(ofSize: 12)
    private var textColor: NSColor = .labelColor

    init(text: Binding<String>) { _text = text }

    func nsFont(_ f: NSFont) -> Self { var c = self; c.font = f; return c }
    func nsTextColor(_ c: NSColor) -> Self { var s = self; s.textColor = c; return s }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }

        Self.configure(tv, delegate: context.coordinator, font: font, textColor: textColor)
        tv.string = text

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        return scrollView
    }

    /// Everything that makes one of these text views what it is. Split out of
    /// `makeNSView` so a test can build a configured view without a SwiftUI
    /// Context, which is what lets the undo ownership below be asserted at all.
    static func configure(_ tv: NSTextView, delegate: NSTextViewDelegate?,
                          font: NSFont, textColor: NSColor) {
        tv.delegate = delegate
        tv.font = font
        tv.textColor = textColor

        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        // Safe only because the delegate supplies an undo manager owned by the
        // coordinator. See Coordinator.undoManager(for:) for why (#196).
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.usesRuler = false

        // The whole point of this wrapper
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = false   // highlight, don't auto-fix
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false

        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        // Only replace string when it changed externally: preserves cursor position
        if tv.string != text {
            Self.replaceTextExternally(tv, with: text, coordinator: context.coordinator)
        }
        tv.font = font
        tv.textColor = textColor
    }

    /// Writes a value that came from outside the editor (a regeneration, an
    /// undo of a whole day, a revision landing) into the text view.
    ///
    /// Assigning `string` bypasses the undo system, so the operations already on
    /// the stack describe ranges in a buffer that no longer exists. They are
    /// dropped rather than left to be replayed against the wrong text. Dropping
    /// them is precise now that the stack belongs to this editor alone: it can't
    /// take another field's history with it.
    static func replaceTextExternally(_ tv: NSTextView, with newText: String,
                                      coordinator: Coordinator) {
        let saved = tv.selectedRanges
        tv.string = newText
        coordinator.editorUndoManager.removeAllActions()

        // A shorter replacement leaves the old selection out of bounds, which
        // throws rather than merely looking wrong.
        let limit = (newText as NSString).length
        let clamped = saved.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= limit else { return nil }
            return NSValue(range: NSRange(location: range.location,
                                          length: min(range.length, limit - range.location)))
        }
        tv.selectedRanges = clamped.isEmpty
            ? [NSValue(range: NSRange(location: limit, length: 0))]
            : clamped
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpellCheckingTextEditor?

        /// This editor's own undo stack.
        ///
        /// Without it, an NSTextView whose delegate doesn't implement
        /// `undoManager(for:)` registers its operations on the WINDOW's shared
        /// manager. NSUndoManager holds an unowned reference to each action's
        /// target ("to prevent retain cycles", per the SDK header), and these
        /// editors are destroyed constantly while the window lives on: switching
        /// posting day, switching event (the whole screen remounts on
        /// `.id(event.id)`), dismissing a sheet. Holding Cmd+Z walked key repeat
        /// past the live editor's operations into a stale one and sent
        /// `_undoRedoTextOperation:` to a freed text view, killing the app (#196).
        ///
        /// The coordinator outlives its text view, so this stack dies with the
        /// editor and nothing dangles. It also stops undo history leaking
        /// between unrelated fields, which was wrong on its own: Cmd+Z in one
        /// caption could undo an edit made to another caption or the blog body.
        let editorUndoManager = UndoManager()

        /// For tests, which build a configured text view without a SwiftUI
        /// Context and so have no parent view to hand over.
        override init() {
            self.parent = nil
            super.init()
        }

        init(_ parent: SpellCheckingTextEditor) {
            self.parent = parent
            super.init()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent?.text != tv.string {
                parent?.text = tv.string
            }
        }
    }
}
