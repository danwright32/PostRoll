import SwiftUI

/// The handles the app has learned, listed so they can be checked (#903).
///
/// The books fill a handle into every future event with the same performer
/// name, organisation or venue, and nothing showed what they held. A wrong
/// entry could only be found by opening an event and noticing the wrong value
/// in a field, and only corrected by editing that row and advancing past
/// Review. On 2026-08-27 the correct handle for a company had to be read out of
/// the preferences plist by hand to answer "what does the app think this is".
///
/// All three books, decided by Dan on 2026-08-27. The issue named performers
/// because that is where the problem was noticed; the org book is where the
/// worst data actually is.
struct SavedHandlesSection: View {
    /// Injected so a test rendering this screen never touches the book Dan has
    /// built up across every event he has shot (L2). The app passes the shared
    /// one, the way it does for the posting preset store.
    let book: HandleBook

    /// Bumped after every write, so the lists are re-read. The book is a plain
    /// store rather than an observable one, so nothing else would tell this
    /// view that what it is showing has changed (L14).
    @State private var revision = 0

    var body: some View {
        ForEach(HandleBook.Kind.allCases) { kind in
            Section {
                let entries = book.entries(in: kind)
                if entries.isEmpty {
                    // An empty book and a book nobody has looked at are the
                    // same picture, so this says which (L10).
                    Text("Nothing learned yet. Handles are saved when you "
                         + "advance past the Review screen.")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                } else {
                    ForEach(entries) { entry in
                        SavedHandleRow(entry: entry, kind: kind, book: book,
                                       onChanged: { revision += 1 })
                    }
                }
            } header: {
                Text("Saved Handles: \(kind.title)")
            } footer: {
                Text(kind.explanation)
                    .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                    .font(.system(size: 11))
            }
        }
        .id(revision)
    }
}

private struct SavedHandleRow: View {
    let entry: HandleBook.Entry
    let kind: HandleBook.Kind
    let book: HandleBook
    let onChanged: () -> Void

    @State private var value: String = ""
    @State private var refused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.sm) {
                Text(entry.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                    .frame(width: 200, alignment: .leading)
                    .lineLimit(1)
                    .help(entry.name)

                TextField("handle", text: $value)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)

                Button {
                    book.removeEntry(name: entry.name, in: kind)
                    onChanged()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(PaintedSurfaces.quietMark)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forget \(entry.name)")
                .help("Forget this one. It will be learned again the next time "
                      + "you advance past Review with a handle on that row.")
            }

            // Two different things to say, and they are not alternatives. The
            // first is what the book is doing with this value right now; the
            // second is what just happened to an edit (L11).
            if !entry.isUsable {
                Label("Not an Instagram handle, so it is not being filled in "
                      + "anywhere. Correct it here or forget it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(PaintedSurfaces.stateWarningText)
            }
            if refused {
                Label("Not saved: that is not an Instagram handle. The old "
                      + "value is still here.",
                      systemImage: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(PaintedSurfaces.stateWarningText)
            }
        }
        .onAppear { value = entry.value }
    }

    /// The refusal is READ BACK rather than predicted, so this says what the
    /// book actually did rather than what it was expected to do (L12).
    private func commit() {
        book.setEntry(name: entry.name, value: value, in: kind)
        let now = book.entries(in: kind).first { $0.name == entry.name }?.value
        refused = now != nil && now != value.trimmingCharacters(in: .whitespaces)
        if !refused { onChanged() }
    }
}
