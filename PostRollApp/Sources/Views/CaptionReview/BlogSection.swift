import SwiftUI
import AppKit


struct BlogSection: View {
    @Binding var blog: BlogOutput
    var photoCount: Int = 0
    /// The SEO description and details block (#284). Passed in rather than
    /// derived from `blog`: they are facts about the event, and they must never
    /// be part of the post body.
    var metadataFields: [BlogMeta.CopyField] = []
    let isExpanded: Bool
    let onToggle: () -> Void
    /// Start a revision. Not awaited, and nothing comes back: this section is
    /// destroyed on every event switch and used to hold the only copy of the
    /// run's progress, its error and the blog to undo to (#718).
    let onRevise: (String, Bool) -> Void
    var onSwapPhotos: (([URL]) -> Void)? = nil
    /// The two runs' state, read from `CaptionWorkManager` by the screen above.
    var isRevising: Bool = false
    var revisionError: String? = nil
    /// The revision landed and only the brand voice note did not (#462). Its
    /// own value rather than a second meaning for `revisionError` (L53).
    var brandVoiceError: String? = nil
    var isSwappingPhotos: Bool = false
    var photoSwapError: String? = nil
    /// What the two runs need to show working / still alive / failed rather
    /// than a bare spinner (#1128). Both are several sequential Claude calls,
    /// one of them image-carrying, and both drew an indefinite spinner that
    /// looked identical whether the call was progressing, hung or dead.
    /// Optional so a preview or a test can render the section without them,
    /// which falls back to the spinner rather than drawing an indicator with
    /// no start time to measure from.
    var eventID: UUID? = nil
    var revisionStartedAt: Date? = nil
    var photoSwapStartedAt: Date? = nil
    /// Retry the repairs the pass could not finish (#1160).
    ///
    /// Optional like the others, so a preview renders without it. When it is
    /// nil the control is absent, which is the same as having nothing to
    /// retry: the panel must never draw a button that does nothing (L109).
    var onRetryRepairs: (([String]) -> Void)? = nil
    var isRetryingRepairs: Bool = false
    var retryError: String? = nil
    /// What the last retry actually did, in a sentence.
    ///
    /// Separate from `retryError`, because a retry that rewrote nothing is not
    /// an error: the app tried and its own checks refused the result. Without
    /// this the control acts and reports nothing, which is the complaint this
    /// issue was raised about one step further on (L98).
    var retryNote: String? = nil
    var retryStartedAt: Date? = nil
    /// The blog as it stood before the last revision or swap, so Restore is
    /// offered after this section has been rebuilt (L97).
    var undoBlog: BlogOutput? = nil
    var onUndoBlogChange: (() -> Void)? = nil
    @State private var showingPreview = false
    @State private var showingRevision = false
    @State private var feedbackText = ""
    @State private var saveToBrandVoice = false
    /// A photo import that could not be copied into app storage. Local,
    /// because it happens before any run starts and is over in an instant.
    @State private var photoImportError: String? = nil
    /// Confirms the copy landed. Reset whenever the text changes, so it never
    /// claims the clipboard holds something it no longer does.
    @State private var copiedDraft = false
    /// Which metadata field was last copied, by label. One value rather than
    /// one flag per field, so copying the second cannot leave the first still
    /// claiming the clipboard (#284).
    @State private var copiedMetadata: String? = nil

    /// The SEO description and details block, each with its own copy control
    /// (#284).
    ///
    /// Deliberately below the body and inside its own bordered card, because
    /// the risk runs both ways: leaving these only in the export folder repeats
    /// #205 (the title was generated, stored and shown, and Dan still typed it
    /// by hand, because the surface he copies from carried the body alone), and
    /// pasting them INTO the body is a new way to ship the wrong thing, since a
    /// fact block inside the post reaches the AI round trip (#283).
    @ViewBuilder
    private var metadataPanel: some View {
        if !metadataFields.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("POST METADATA")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Text("Not part of the post. Paste these into the page's own fields, not into the body.")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(metadataFields, id: \.label) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(field.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PaintedSurfaces.bodyText)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(field.text, forType: .string)
                                copiedMetadata = field.label
                            } label: {
                                Label(copiedMetadata == field.label ? "Copied" : "Copy",
                                      systemImage: copiedMetadata == field.label
                                                   ? "checkmark" : "doc.on.doc")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                            .help(field.help)
                            .accessibilityLabel("Copy \(field.label)")
                        }
                        Text(field.text)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(PaintedSurfaces.deepPage)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
                    )
            )
        }
    }

    /// The deterministic checks from #201. They report rather than rewrite,
    /// so this panel IS the feature: the quoted text is what lets Dan fix each
    /// one. Once he edits the body the checks no longer describe it, so the
    /// panel says so instead of continuing to assert stale findings.
    @ViewBuilder
    private var blogFindingsPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Whether anything CHECKED this post, always, findings or not
            // (#1138).
            //
            // With repairs silent, an empty panel is the normal state, and it
            // was produced identically by five different things: a genuinely
            // clean post, a pass that threw before its loop, a pass whose tail
            // never ran, check_blog itself breaking, and the process being
            // killed at its deadline mid-pass. Without this line the surface
            // Dan actually reads cannot tell him which (L98, L152, L319).
            if let note = blog.repairPass.note {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: blog.repairPass.ran
                          ? (blog.repairPass.endedEarly
                             ? "clock.badge.exclamationmark" : "checkmark.circle")
                          : "questionmark.circle")
                        .font(.system(size: 11))
                    Text(note)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Draft checks: \(note)")
            }

            if let summary = blog.findingsSummary {
                FindingsPanel(summary: summary,
                              findings: blog.findings,
                              isStale: blog.findingsAreStale,
                              subject: "draft")
            }
        }
    }

    /// The markers a retry would name, from the findings already on screen.
    ///
    /// Derived rather than stored, so the control disappears the moment the
    /// findings it was offered for do (L14).
    private var retryableMarkers: [String] {
        FindingsDisplay.retryableTargets(findings: blog.findings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BLOG POST")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(isExpanded ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                        if !blog.title.isEmpty {
                            Text(blog.title)
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    // Visible while collapsed, so the checks are not something
                    // Dan has to open the section to discover (#201).
                    if let summary = blog.findingsSummary {
                        // The ink and the wash from one place, which is what
                        // captionFindings exists for: this drew its own summary
                        // in a colour chosen beside the wash it sits on, so the
                        // two could disagree and the measured pair covered
                        // neither (#600, #620).
                        let findings = PaintedSurfaces.captionFindings(
                            stale: blog.findingsAreStale)
                        Text(summary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(findings.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(findings.badge))
                            .accessibilityLabel("Blog checks: \(summary)")
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    blogFindingsPanel

                    ReviewTextArea(label: "Title", text: $blog.title, minHeight: 36)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("BODY (MARKDOWN)")
                                .font(.system(size: 9, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                            Spacer()
                            // One thing to copy, title included (#205). The
                            // title was generated, stored and shown, and Dan
                            // still typed it by hand every time because the
                            // surface he copies from carried the body alone.
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    BlogDraftText.copyText(title: blog.title, body: blog.body),
                                    forType: .string)
                                copiedDraft = true
                            } label: {
                                Label(copiedDraft ? "Copied" : "Copy title + body",
                                      systemImage: copiedDraft ? "checkmark" : "doc.on.doc")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                            .help("Copy the post with its title, ready to paste")

                            Button(showingPreview ? "Edit" : "Preview") {
                                showingPreview.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                        }
                        if showingPreview {
                            ScrollView {
                                Group {
                                    if let attr = try? AttributedString(markdown: blog.body) {
                                        Text(attr)
                                    } else {
                                        Text(blog.body)
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(PaintedSurfaces.bodyText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .frame(minHeight: 280)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .fill(PaintedSurfaces.deepPage)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Radius.sm)
                                            .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
                                    )
                            )
                        } else {
                            BlogBodyEditor(text: $blog.body)
                        }
                    }

                    metadataPanel

                    if showingRevision {
                        RevisionPanel(
                            feedbackText: $feedbackText,
                            saveToBrandVoice: $saveToBrandVoice,
                            isRevising: isRevising,
                            error: revisionError,
                            brandVoiceError: brandVoiceError,
                            progress: (eventID.map {
                                RevisionPanel.Progress(
                                    eventID: $0, startedAt: revisionStartedAt,
                                    run: .blog, estimate: "~2 to 5 min")
                            }),
                            onApply: { applyRevision() },
                            onCancel: {
                                showingRevision = false
                                feedbackText = ""
                                saveToBrandVoice = false
                            }
                        )
                    } else {
                        HStack(spacing: Spacing.md) {
                            Button("Revise with feedback…") { showingRevision = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                            if onSwapPhotos != nil {
                                if isSwappingPhotos {
                                    // Not a bare spinner (#1128). This is an
                                    // image-carrying Claude call at a 300
                                    // second timeout, and after this milestone
                                    // up to seven more behind it, so Dan has to
                                    // be able to tell a run that is working
                                    // from one that has stalled.
                                    if let eventID {
                                        LongRunIndicator(
                                            label: "Updating photos…",
                                            startedAt: photoSwapStartedAt,
                                            eventID: eventID,
                                            run: .blogPhotos,
                                            estimate: "~1 to 3 min")
                                    } else {
                                        HStack(spacing: 4) {
                                            ProgressView().controlSize(.mini).tint(PaintedSurfaces.secondaryText)
                                            Text("Updating photos…")
                                                .font(.system(size: 12))
                                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                        }
                                    }
                                } else {
                                    Button("Change photos (\(photoCount))…") { pickAndSwapPhotos() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(PaintedSurfaces.secondaryText)
                                }
                            }
                            // Shown only when something can actually be
                            // retried (#1160). Two of the five outcomes say
                            // "Worth trying again" in as many words, and until
                            // this existed nothing did: the panel named a
                            // recovery step nothing could perform (L109).
                            if let onRetryRepairs, !retryableMarkers.isEmpty {
                                if isRetryingRepairs {
                                    if let eventID {
                                        LongRunIndicator(
                                            label: "Retrying \(retryableMarkers.count)…",
                                            startedAt: retryStartedAt,
                                            eventID: eventID,
                                            run: .blogRetry,
                                            estimate: RepairRetryEstimate.text(
                                                markerCount: retryableMarkers.count))
                                    } else {
                                        HStack(spacing: 4) {
                                            ProgressView().controlSize(.mini).tint(PaintedSurfaces.secondaryText)
                                            Text("Retrying…")
                                                .font(.system(size: 12))
                                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                        }
                                    }
                                } else {
                                    // The count is in the label because the
                                    // retry is paid: Dan should know what he
                                    // is about to spend before he spends it.
                                    Button("Try \(retryableMarkers.count) again") {
                                        onRetryRepairs(retryableMarkers)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                }
                            }
                            if undoBlog != nil {
                                Button("Restore previous") {
                                    onUndoBlogChange?()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                            }
                        }
                        // Two different causes, two rows. A file that could
                        // not be copied into app storage and a swap the model
                        // refused are different problems with different next
                        // steps, and one row for both would say the wrong thing
                        // for one of them (L11).
                        if let err = photoImportError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.stateErrorText)
                        }
                        if let err = photoSwapError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.stateErrorText)
                        }
                        // Its own row, for the reason the two above have their
                        // own: a retry that could not run and a swap the model
                        // refused are different problems (L11, L53).
                        if let err = retryError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.stateErrorText)
                        }
                        // What the retry DID, in ordinary type rather than the
                        // error colour: rewriting none of what it tried is an
                        // honest outcome, not a fault.
                        if let note = retryNote, retryError == nil,
                           !isRetryingRepairs {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
        }
        // The panel is closed by the run finishing, not by the press that
        // started it (#718).
        .onChange(of: isRevising) { revisionSettled() }
        // A stale "Copied" would claim the clipboard holds text that has since
        // changed (#205).
        .onChange(of: blog.body) { copiedDraft = false }
        .onChange(of: blog.title) { copiedDraft = false }
        // Same rule for the metadata: these change when the event's own facts
        // do, not when the draft does, so they watch their own text.
        .onChange(of: metadataFields) { copiedMetadata = nil }
    }

    private func pickAndSwapPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic, .image]
        panel.title = "Select Blog Photos"
        panel.message = "Choose photos for the blog post (4\u{2013}7 recommended)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // Copy into app storage before these become the blog's photo paths, so
        // a later render can't fail on a folder the user renamed (#77).
        let outcome = ImportedPicks.copy(panel.urls)
        photoImportError = outcome.failureMessage
        let urls = outcome.stored
        guard !urls.isEmpty else { return }
        onSwapPhotos?(urls)
    }

    /// Hand the feedback over and let go of it.
    private func applyRevision() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRevise(trimmed, saveToBrandVoice)
    }

    /// Clear the composer once a revision has finished with nothing left to say.
    ///
    /// Held open on a failed brand voice note, because the note IS the text in
    /// this panel and clearing it is what threw it away (#462).
    private func revisionSettled() {
        guard !isRevising, brandVoiceError == nil, revisionError == nil else { return }
        showingRevision = false
        feedbackText = ""
        saveToBrandVoice = false
    }
}
struct BlogBodyEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        SpellCheckingTextEditor(text: $text)
            .nsFont(.systemFont(ofSize: 12))
            .nsTextColor(NSColor(PaintedSurfaces.bodyText))
            .focused($focused)
            .frame(minHeight: 280)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(PaintedSurfaces.deepPage)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(
                                focused ? Color.roseGold : Color.creamEdge,
                                lineWidth: focused ? 1.5 : 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Hashtags editor

struct HashtagsEditor: View {
    @Binding var hashtags: [String]
    @Environment(HashtagStore.self) private var hashtagStore

    // Flat editable text — joined with spaces
    @State private var raw: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.sm) {
                Text("HASHTAGS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Spacer()
                Text("\(hashtags.count)/30")
                    .font(.system(size: 9))
                    .foregroundStyle(hashtags.count > 30 ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                if !hashtagStore.presets.isEmpty {
                    Menu {
                        ForEach(hashtagStore.presets) { preset in
                            Button(preset.name) {
                                var updated = hashtags
                                for tag in preset.tags where !updated.contains(tag) {
                                    updated.append(tag)
                                }
                                hashtags = updated
                                raw = updated.joined(separator: " ")
                            }
                        }
                    } label: {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                            .foregroundStyle(PaintedSurfaces.iconAccent)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Apply a hashtag preset")
                    .help("Apply a hashtag preset")
                    .accessibilityLabel("Apply a hashtag preset")
                }
            }
            // Plain single-line TextField — TextField has its own internal
            // cursor-following scroll for long content, so wrapping it in an
            // outer ScrollView (with a hardcoded 2000pt minWidth) caused the
            // visible scroll-past-end-of-text behavior.
            TextField("#tag1 #tag2 #tag3", text: $raw)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(PaintedSurfaces.bodyText)
                .focusEffectDisabled()
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(PaintedSurfaces.deepPage)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.xs)
                            .strokeBorder(
                                focused ? Color.roseGold : Color.creamEdge,
                                lineWidth: focused ? 1.5 : 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: focused)
                .onChange(of: raw) { _, newVal in
                    hashtags = newVal
                        .split(separator: " ")
                        .map { String($0) }
                        .filter { !$0.isEmpty }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused {
                        // Normalize on blur
                        raw = hashtags.joined(separator: " ")
                    }
                }
        }
        .onAppear { raw = hashtags.joined(separator: " ") }
        .onChange(of: hashtags) { _, tags in
            if !focused {
                raw = tags.joined(separator: " ")
            }
        }
    }
}

// MARK: - Alt texts section

struct AltTextsSection: View {
    @Binding var altTexts: [String]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("ALT TEXTS (\(altTexts.count))")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(altTexts.indices, id: \.self) { i in
                    AltTextRow(index: i, text: binding(for: i))
                }
            }
        }
    }

    // Bounds-checked binding so a stale row index can never trap in Array._checkSubscript
    // if altTexts shrinks out from under the ForEach.
    private func binding(for i: Int) -> Binding<String> {
        Binding(
            get: { i < altTexts.count ? altTexts[i] : "" },
            set: { if i < altTexts.count { altTexts[i] = $0 } }
        )
    }
}
struct AltTextRow: View {
    let index: Int
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text("P\(index + 1)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .padding(.top, 8)
                .frame(width: 20, alignment: .leading)
            SpellCheckingTextEditor(text: $text)
                .nsFont(.systemFont(ofSize: 11))
                .nsTextColor(NSColor(PaintedSurfaces.bodyText))
                .focused($focused)
                .frame(minHeight: 44)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(PaintedSurfaces.deepPage)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.xs)
                                .strokeBorder(
                                    focused ? Color.roseGold : Color.creamEdge,
                                    lineWidth: focused ? 1.5 : 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

// MARK: - Shared text area

struct ReviewTextArea: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 80
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.secondaryText)
            SpellCheckingTextEditor(text: $text)
                .nsFont(.systemFont(ofSize: 12))
                .nsTextColor(NSColor(PaintedSurfaces.bodyText))
                .focused($focused)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(PaintedSurfaces.deepPage)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(
                                    focused ? Color.roseGold : Color.creamEdge,
                                    lineWidth: focused ? 1.5 : 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
