import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var saved = false

    // Legacy-data reclaim (#47): nil until probed; 0 means nothing to reclaim.
    @State private var reclaimableBytes: Int64? = nil
    @State private var isReclaiming = false
    @State private var showReclaimConfirm = false
    @State private var reclaimResult: String?

    var body: some View {
        Form {
            Section {
                SecureField("sk-ant-…", text: $apiKey)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 380)
                    .onChange(of: apiKey) { saved = false }

                HStack {
                    Button("Save") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            KeychainStore.deleteAPIKey()
                        } else {
                            KeychainStore.saveAPIKey(trimmed)
                        }
                        saved = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces) ==
                              (KeychainStore.readAPIKey() ?? ""))

                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13))
                    }
                }
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Text("Used to call Claude directly, bypassing the CLI for faster generation. Get a key at console.anthropic.com.")
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
