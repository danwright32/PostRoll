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

        func read() -> String? {
            switch self {
            case .keychain:          return KeychainStore.readAPIKey()
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

    @State private var apiKey: String

    /// What the store held when it was last read (#935).
    ///
    /// Held beside the typed value rather than fetched to answer the Save
    /// button's disabled state, which is what that modifier used to do: a
    /// keychain read on every render pass, so typing one character re-read it.
    /// A keychain read is a privileged call, not a cheap one.
    ///
    /// Read once here and moved only when a write actually LANDS, which is the
    /// part that has to stay correct. A refused save or delete leaves it alone,
    /// so the typed value still differs from it and the button stays live to be
    /// retried; a button that went quiet there would leave somebody facing a
    /// screen saying the write failed and no way to try again (#112, #448,
    /// L109).
    ///
    /// What this deliberately gives up, said out loud rather than left as a gap
    /// (L129): the screen no longer notices a key changed by something OTHER
    /// than this app while Settings is open. The app is the only writer of this
    /// entry, and the previous behaviour bought that at the price of a
    /// privileged call per redraw.
    @State private var storedKey: String

    init(keySource: KeySource = .keychain, book: HandleBook = .shared) {
        self.keySource = keySource
        self.book = book
        let stored = keySource.read() ?? ""
        _apiKey = State(initialValue: stored)
        _storedKey = State(initialValue: stored)
    }

    @State private var saved = false
    /// Set when a save was refused by the keychain, so a write that did not
    /// land cannot present as a successful one (#112).
    @State private var saveError: String?

    // Default posting layout for new events (#66). Per-event overrides live on
    // the Export page; this is the fallback an event uses until it's overridden.
    //
    // Taken from the environment rather than built here, the way the analytics
    // and hashtag stores are (#727). This screen is compiled into the test
    // bundle, so a store it built itself was one reading Dan's real preference
    // from inside any test that rendered the screen; the app provides the one
    // store in PostRollApp.
    @Environment(PostingPresetStore.self) private var presetStore

    // Legacy-data reclaim (#47): nil until probed; 0 means nothing to reclaim.
    @State private var reclaimableBytes: Int64? = nil
    @State private var isReclaiming = false
    @State private var showReclaimConfirm = false
    @State private var reclaimResult: String?

    var body: some View {
        Form {
            Section {
                // Placeholder shows the SHAPE of a whole key rather than just
                // its prefix: "sk-ant-…" read as the field already accounting
                // for the prefix, so only the part after it got pasted, and the
                // result was the same generic "invalid x-api-key" as a wrong
                // key with nothing to tell the two apart (#128).
                SecureField("Paste the whole key, starting sk-ant-", text: $apiKey)
                    .textFieldStyle(.automatic)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 380)
                    .onChange(of: apiKey) { saved = false; saveError = nil }

                if let warning = KeychainStore.formatWarning(for: apiKey) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PaintedSurfaces.stateWarningText)
                        .font(.system(size: 11))
                        .frame(width: 380, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Save") {
                        // One implementation of what a press does, held in
                        // KeychainStore so every branch of it can be exercised
                        // with no keychain (#935). It decides what is stored,
                        // whether to show the mark, and what to say when the
                        // write was refused, together: three fields set
                        // separately here is how a refused write came to
                        // present as a successful one (#112, L53).
                        let outcome = KeychainStore.save(typed: apiKey,
                                                         stored: storedKey)
                        storedKey = outcome.stored
                        saved = outcome.saved
                        saveError = outcome.error
                    }
                    .buttonStyle(.borderedProminent)
                    // Unchanged, or not long enough to be a whole key (#348).
                    // The warning above says which, so a disabled button is
                    // never unexplained.
                    //
                    // Against the value held in state rather than one fetched
                    // here (#935). This ran on every render pass and each run
                    // was a keychain read.
                    .disabled(!KeychainStore.canSave(typed: apiKey,
                                                     stored: storedKey))

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
                Text("Anthropic API Key")
            } footer: {
                Text(.init(SettingsCopy.apiKeyFooter))
                    .foregroundStyle(PaintedSurfaces.readableSecondaryLabel)
                    .font(.system(size: 11))
            }

            Section {
                Picker("Default layout", selection: Binding(
                    get: { presetStore.selected },
                    set: { presetStore.selected = $0; presetStore.save() }
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
