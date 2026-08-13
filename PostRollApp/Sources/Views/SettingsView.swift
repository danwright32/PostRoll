import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var saved = false
    /// Set when a save was refused by the keychain, so a write that did not
    /// land cannot present as a successful one (#112).
    @State private var saveError: String?

    // Default posting layout for new events (#66). Per-event overrides live on
    // the Export page; this is the fallback an event uses until it's overridden.
    @State private var presetStore = PostingPresetStore()

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
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 380)
                    .onChange(of: apiKey) { saved = false; saveError = nil }

                if let warning = KeychainStore.formatWarning(for: apiKey) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                        .frame(width: 380, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Save") {
                        let trimmed = KeychainStore.sanitize(apiKey)
                        if trimmed.isEmpty {
                            // Clearing the field means removing the key, and a
                            // keychain that refuses that used to report exactly
                            // like one that did it: the green Saved state while
                            // the key sat there and the next run kept billing
                            // against it (#448).
                            if KeychainStore.deleteAPIKey() {
                                saved = true
                                saveError = nil
                            } else {
                                saved = false
                                saveError = SettingsCopy.keyNotRemoved
                            }
                        } else if KeychainStore.saveAPIKey(trimmed) {
                            saved = true
                            saveError = nil
                        } else {
                            // A refused write used to report exactly like a
                            // successful one, so the next run failed with an
                            // authentication error pointing nowhere near the
                            // real cause (#112).
                            saved = false
                            saveError = "The key could not be saved to your keychain. "
                                      + "Nothing was stored, so generation will keep using "
                                      + "the previous key if there is one."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    // Unchanged, or not long enough to be a whole key (#348).
                    // The warning above says which, so a disabled button is
                    // never unexplained.
                    .disabled(KeychainStore.sanitize(apiKey) ==
                              (KeychainStore.readAPIKey() ?? "")
                              || !KeychainStore.isSavable(apiKey))

                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13))
                    }
                }

                if let saveError {
                    Label(saveError, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                        .frame(width: 380, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Text(.init(SettingsCopy.apiKeyFooter))
                    .foregroundStyle(.secondary)
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
                Text("The layout new events start with. Balanced posts a 4 photo carousel with a collage story on Sunday, Monday, and Wednesday; Classic posts a single photo Sunday and Monday plus a 10 photo Wednesday. You can override this for any single event on its Export page.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }

            if let bytes = reclaimableBytes, bytes > 0 {
                Section {
                    HStack {
                        if isReclaiming {
                            ProgressView().controlSize(.small)
                            Text("Reclaiming…").foregroundStyle(.secondary)
                        } else {
                            Button("Reclaim \(byteString(bytes))…", role: .destructive) {
                                showReclaimConfirm = true
                            }
                        }
                        if let reclaimResult {
                            Spacer()
                            Text(reclaimResult)
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11))
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Your data now lives in Application Support. The original copies in ~/Documents/PostRoll are duplicates and safe to delete. The Python project files there are left untouched.")
                        .foregroundStyle(.secondary)
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
