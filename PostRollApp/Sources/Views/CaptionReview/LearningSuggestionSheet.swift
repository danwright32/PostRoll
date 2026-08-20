import SwiftUI
import AppKit


struct LearningSuggestionSheet: View {
    let suggestion: String
    /// Returns nil when the note was written, or what to say when it was not.
    /// The sheet stays open on a failure, because the text it holds is the only
    /// copy of what Dan typed (#462).
    let onSave: (String) -> String?
    let onSkip: () -> Void

    @State private var editedSuggestion: String
    @State private var saveError: String?

    init(suggestion: String, onSave: @escaping (String) -> String?, onSkip: @escaping () -> Void) {
        self.suggestion = suggestion
        self.onSave = onSave
        self.onSkip = onSkip
        _editedSuggestion = State(initialValue: suggestion)
    }

    private var trimmed: String {
        editedSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("PATTERN FOUND IN YOUR EDITS")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)

                Text("Based on how you revised these captions, there may be something worth adding to your brand voice. Edit the wording below before saving if you want to refine it:")
                    .font(.light(12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SpellCheckingTextEditor(text: $editedSuggestion)
                .nsFont(.systemFont(ofSize: 13))
                .nsTextColor(NSColor(PaintedSurfaces.bodyText))
                .padding(Spacing.sm)
                .frame(minHeight: 120, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(PaintedSurfaces.noteFieldFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(PaintedSurfaces.accentBorder.opacity(0.2), lineWidth: 1)
                        )
                )

            Text("Adding this will apply to all future caption generation.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.md) {
                Button("Add to brand voice") { saveError = onSave(trimmed) }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(trimmed.isEmpty)
                Button("Reset") { editedSuggestion = suggestion }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .disabled(editedSuggestion == suggestion)
                Spacer()
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .background(PaintedSurfaces.page)
    }
}
