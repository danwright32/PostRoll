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

        tv.delegate = context.coordinator
        tv.string = text
        tv.font = font
        tv.textColor = textColor

        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
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

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        // Only replace string when it changed externally — preserves cursor position
        if tv.string != text {
            let saved = tv.selectedRanges
            tv.string = text
            if !saved.isEmpty { tv.selectedRanges = saved }
        }
        tv.font = font
        tv.textColor = textColor
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpellCheckingTextEditor
        init(_ parent: SpellCheckingTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string {
                parent.text = tv.string
            }
        }
    }
}
