import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var saved = false

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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
