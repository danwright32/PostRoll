import SwiftUI

struct SettingsView: View {

    /// Where the stored key is read from (#918).
    ///
    /// This screen could not be rendered for review because building it read
    /// the real key out of the macOS keychain, which would have put a live
    /// secret read inside the test suite on every run and every machine. No
    /// other test here does that: `APIKeyDeliveryTests` hands its own key in,
    /// and `KeychainStoreTests` only exercises the pure helpers (L2).
    ///
    /// A named value rather than a closure, because the DEFAULT is the half
    /// worth pinning. A seam whose default silently became the fixture would
    /// leave the real screen reading nothing and showing an empty field, and
    /// two closures cannot be compared to catch that. This can, and
    /// `SettingsKeySourceTests` does.
    ///
    /// Nothing about how the key is stored, saved or delivered changes. Only
    /// where the screen looks when something other than the app builds it.
    enum KeySource: Equatable {
        case keychain
        case fixed(String?)

        func read(_ secret: KeychainStore.Secret = .anthropic) -> String? {
            switch self {
            case .keychain:          return KeychainStore.read(secret)
            case .fixed(let value):  return value
            }
        }
    }

    let keySource: KeySource

    /// The handle book the saved handles panes list (#918).
    ///
    /// Injected because a rendered pane has to picture a book somebody CHOSE.
    ///
    /// A correction to what this comment first said. It claimed a render read
    /// the book Dan has built up across every event he has shot. It does not:
    /// `HandleBook` reads `AppPreferences.store`, and under `POSTROLL_TESTS`
    /// that is a scratch suite, so the shared book in a test is already off his
    /// data. The keychain above is the one with no such redirection, which is
    /// why that seam is an L2 matter and this one is not.
    ///
    /// The reason that survives is still a reason. A shared scratch suite holds
    /// whatever every other test in the run happened to write, so a picture of
    /// the saved handles pane would be a picture of leakage, changing with test
    /// order rather than saying anything (L205). `SavedHandlesSection` already
    /// took its book as a parameter and this screen was the call site handing
    /// it `.shared`. The app still passes the shared one.
    let book: HandleBook

    init(keySource: KeySource = .keychain, book: HandleBook = .shared) {
        self.keySource = keySource
        self.book = book
    }

    // Default posting layout for new events (#66). Per-event overrides live on
    // the Export page; this is the fallback an event uses until it's overridden.
    //
    // Taken from the environment rather than built here, the way the analytics
    // and hashtag stores are (#727). This screen is compiled into the test
    // bundle, so a store it built itself was one reading Dan's real preference
    // from inside any test that rendered the screen; the app provides the one
    // store in PostRollApp.
    @Environment(PostingPresetStore.self) private var presetStore
    /// Told when the Meta token changes, so the records that failed for want of
    /// one are asked about again (#1004).
    @Environment(AccountNumbersManager.self) private var accountNumbers
    /// Everything a layout change has to reach (#1025). Changing the default
    /// moves every event that has no override of its own, and until now that
    /// happened silently: the per event control has confirmed and named what it
    /// replaces since #1007, while this one, which can move many events at
    /// once, did neither.
    @Environment(AppState.self) private var appState
    @Environment(GenerationManager.self) private var genManager
    /// NOT `@Environment`: `withAppOwners` does not provide this manager, so
    /// the per event control takes the shared one the same way.
    var previews: PreviewGraphicsManager = .shared

    /// The layout waiting on the confirmation, and what it would do.
    @State private var pendingLayout: (preset: PostingPreset,
                                       impact: SettingsLayoutSwitch.Impact)?

    // Legacy-data reclaim (#47): nil until probed; 0 means nothing to reclaim.
    @State private var reclaimableBytes: Int64? = nil
    @State private var isReclaiming = false
    @State private var showReclaimConfirm = false
    @State private var reclaimResult: String?

    /// Ask before a default layout change rebuilds anything (#1025).
    ///
    /// Confirmed only when there is something to lose, exactly as the per event
    /// control decides: a switch that moves no event applies straight away
    /// rather than raising a question with no consequence behind it.
    private func requestLayout(_ newValue: PostingPreset) {
        let old = presetStore.selected
        guard newValue != old else { return }
        let impact = SettingsLayoutSwitch.impact(from: old, to: newValue,
                                                 events: appState.events)
        if SettingsLayoutSwitch.confirmation(impact) == nil {
            applyLayout(newValue, impact: impact)
        } else {
            pendingLayout = (newValue, impact)
        }
    }

    /// Save the default, then rebuild the events that follow it.
    ///
    /// The setting lands FIRST and stays landed. A rebuild that fails leaves
    /// the day flagged by the manager that ran it, which is the surface that
    /// knows why; rolling the setting back on a failure would leave the app
    /// disagreeing with the picker Dan just moved (L12).
    ///
    /// The work goes through the same two managers the per event control uses,
    /// rather than a second implementation of what a layout change costs (L41).
    private func applyLayout(_ newValue: PostingPreset,
                             impact: SettingsLayoutSwitch.Impact) {
        presetStore.selected = newValue
        presetStore.save()

        for affected in impact.affected {
            if !affected.work.redrawDays.isEmpty {
                _ = previews.startRedraw(affected.work.redrawDays,
                                         for: affected.id, appState: appState)
            }
            if !affected.work.rebuildDays.isEmpty {
                // The images of a rebuilt day are cleared first, so a failed
                // rebuild shows nothing rather than the graphic drawn for the
                // layout this event has just left.
                if var event = appState.events.first(where: { $0.id == affected.id }) {
                    for day in affected.work.rebuildDays {
                        event.previewMediaPaths.removeValue(forKey: day)
                    }
                    appState.updateEvent(event)
                }
                genManager.start(eventID: affected.id,
                                 retryDays: affected.work.rebuildDays,
                                 appState: appState, regenerateGraphics: true)
            }
        }
    }

    var body: some View {
        Form {
            SecretField(secret: .anthropic,
                        footer: SettingsCopy.apiKeyFooter,
                        source: keySource)

            SecretField(secret: .meta,
                        footer: SettingsCopy.metaTokenFooter,
                        source: keySource,
                        onSaved: { accountNumbers.credentialChanged() })

            Section {
                Picker("Default layout", selection: Binding(
                    get: { presetStore.selected },
                    set: { requestLayout($0) }
                )) {
                    ForEach(PostingPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Default Posting Layout")
            } footer: {
                // Built from the presets rather than typed out (#900). The
                // sentence here named two of them and the picker above has
                // always drawn every one, so adding a third would have left
                // this describing a shorter list than the control it explains.
                Text("The layout new events start with. "
                     + PostingPreset.explanations
                     + " You can override this for any single event on its "
                     + "Export page.")
                    .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                    .font(.system(size: 11))
            }

            SavedHandlesSection(book: book)

            if let bytes = reclaimableBytes, bytes > 0 {
                Section {
                    HStack {
                        if isReclaiming {
                            ProgressView().controlSize(.small)
                            Text("Reclaiming…").foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                        } else {
                            Button("Reclaim \(byteString(bytes))…", role: .destructive) {
                                showReclaimConfirm = true
                            }
                        }
                        if let reclaimResult {
                            Spacer()
                            Text(reclaimResult)
                                .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                                .font(.system(size: 11))
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Your data now lives in Application Support. The original copies in ~/Documents/PostRoll are duplicates and safe to delete. The Python project files there are left untouched.")
                        .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .task { await probeReclaimable() }
        .confirmationDialog(
            "Delete the duplicate data in ~/Documents/PostRoll?",
            isPresented: $showReclaimConfirm, titleVisibility: .visible
        ) {
            Button("Delete \(reclaimableBytes.map(byteString) ?? "")", role: .destructive) {
                reclaim()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the migrated copies (photos, programs, audio, previews, events). Your active data in Application Support and the Python project files are not affected.")
        }
        // #1025. The same shape as the per event confirmation: it names what
        // it would rebuild before anything is applied, and says where the
        // events it is NOT touching went.
        .alert("Change the default posting layout?",
               isPresented: Binding(get: { pendingLayout != nil },
                                    set: { if !$0 { pendingLayout = nil } })) {
            Button("Change", role: .destructive) {
                if let pending = pendingLayout {
                    applyLayout(pending.preset, impact: pending.impact)
                }
                pendingLayout = nil
            }
            Button("Cancel", role: .cancel) { pendingLayout = nil }
        } message: {
            Text(pendingLayout.flatMap {
                SettingsLayoutSwitch.confirmation($0.impact)
            } ?? "")
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Probe the reclaimable size off the main thread (it walks the legacy dirs).
    private func probeReclaimable() async {
        let bytes = await Task.detached(priority: .utility) {
            LegacyDataReclaim.reclaimableBytes()
        }.value
        reclaimableBytes = bytes
    }

    private func reclaim() {
        isReclaiming = true
        reclaimResult = nil
        Task {
            let result: Result<LegacyDataReclaim.Report, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try LegacyDataReclaim.reclaim()) }
                catch { return .failure(error) }
            }.value
            await MainActor.run {
                isReclaiming = false
                switch result {
                case .success(let report):
                    reclaimResult = "Freed \(byteString(report.bytesFreed))"
                    reclaimableBytes = 0
                case .failure(let error):
                    reclaimResult = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// One stored secret's field, described rather than written out (#1002).
///
/// This was the Anthropic key's section, spelled out inline with its prefix,
/// its placeholder and its heading typed into the view. A second secret added
/// by copying that block would have carried the first one's prefix into its
/// warning, which is exactly what would have told Dan a perfectly good Meta
/// token "does not start with sk-ant-" while Save stayed live.
///
/// Owns its own typed and stored state rather than taking them from the
/// screen. Two fields cannot share one pair, and a parent holding both would
/// have to thread four values per secret through a `body` that is already the
/// largest on this screen.
struct SecretField: View {
    let secret: KeychainStore.Secret
    /// Markdown, so an address in it is a real link.
    let footer: String
    let source: SettingsView.KeySource
    /// Called when a value actually LANDS, so a secret with a consequence can
    /// have it. Optional because most secrets have none.
    var onSaved: (() -> Void)?

    @State private var typed: String
    @State private var stored: String
    @State private var saved = false
    /// Set when a save was refused by the keychain, so a write that did not
    /// land cannot present as a successful one (#112).
    @State private var saveError: String?

    init(secret: KeychainStore.Secret, footer: String,
         source: SettingsView.KeySource, onSaved: (() -> Void)? = nil) {
        self.secret = secret
        self.footer = footer
        self.source = source
        self.onSaved = onSaved
        let held = source.read(secret) ?? ""
        _typed = State(initialValue: held)
        _stored = State(initialValue: held)
    }

    var body: some View {
        Section {
            // The placeholder shows the SHAPE of a whole value rather than just
            // its prefix: "sk-ant-…" read as the field already accounting for
            // the prefix, so only the part after it got pasted, and the result
            // was the same generic authentication error as a wrong key with
            // nothing to tell the two apart (#128).
            SecureField(secret.placeholder, text: $typed)
                .textFieldStyle(.automatic)
                .font(.system(.body, design: .monospaced))
                .frame(width: 380)
                .onChange(of: typed) { saved = false; saveError = nil }

            if let warning = KeychainStore.warning(for: secret, typed: typed) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(PaintedSurfaces.stateWarningText)
                    .font(.system(size: 11))
                    .frame(width: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Save") {
                    // One implementation of what a press does, held in
                    // KeychainStore so every branch of it can be exercised with
                    // no keychain (#935). It decides what is stored, whether to
                    // show the mark, and what to say when the write was
                    // refused, together: three fields set separately here is
                    // how a refused write came to present as a successful one
                    // (#112, L53).
                    let outcome = KeychainStore.save(secret: secret, typed: typed,
                                                     stored: stored)
                    stored = outcome.stored
                    saved = outcome.saved
                    saveError = outcome.error
                    // A saved Meta token is the remedy `token_rejected` names,
                    // so it has to actually change the state Dan is stuck in
                    // (#1004). Without this, the records that failed for want
                    // of a credential sit there until something else happens to
                    // re-tag those accounts, and the message telling him to
                    // paste a token is one he can obey with no effect (L111).
                    if outcome.saved, secret == .meta {
                        onSaved?()
                    }
                }
                .buttonStyle(.borderedProminent)
                // Unchanged, or not long enough to be a whole value (#348). The
                // warning above says which, so a disabled button is never
                // unexplained.
                //
                // Against the value held in state rather than one fetched here
                // (#935). This ran on every render pass and each run was a
                // keychain read.
                .disabled(!KeychainStore.canSave(secret: secret, typed: typed,
                                                 stored: stored))

                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(PaintedSurfaces.stateSuccessText)
                        .font(.system(size: 13))
                }
            }

            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(PaintedSurfaces.stateErrorText)
                    .font(.system(size: 11))
                    .frame(width: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(secret.heading)
        } footer: {
            Text(.init(footer))
                .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                .font(.system(size: 11))
        }
    }
}
