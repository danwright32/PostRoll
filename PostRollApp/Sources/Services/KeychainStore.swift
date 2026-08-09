import Foundation
import Security

/// Simple keychain wrapper for storing the Anthropic API key.
enum KeychainStore {
    private static let service = "com.dwphotony.PostRoll"
    private static let account = "ANTHROPIC_API_KEY"

    static func readAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key.isEmpty ? nil : key
    }

    /// Strips leading/trailing whitespace AND newlines. Copying a key from a
    /// browser or terminal commonly carries a trailing line break that
    /// `.whitespaces` alone (space/tab only) doesn't catch, which silently
    /// corrupts the stored key: every API call then fails with "invalid
    /// x-api-key" even though the visible text looks correct.
    static func sanitize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prefix every Anthropic API key carries.
    static let keyPrefix = "sk-ant-"

    /// What is wrong with the shape of what was typed, or nil.
    ///
    /// Pasting a key WITHOUT its `sk-ant-` prefix produced the same generic
    /// "invalid x-api-key" as a wrong or expired key, so a formatting slip and
    /// a genuinely bad key were indistinguishable (#128). This is a warning
    /// rather than a gate: the prefix is a strong convention, not something
    /// worth refusing a key over if the format ever changes.
    ///
    /// An empty field is not a warning. Empty means clear the stored key, which
    /// is a legitimate action.
    static func formatWarning(for raw: String) -> String? {
        let cleaned = sanitize(raw)
        guard !cleaned.isEmpty else { return nil }
        guard !cleaned.hasPrefix(keyPrefix) else { return nil }
        return "This does not start with \(keyPrefix). Paste the WHOLE key, "
             + "including the \(keyPrefix) at the front, not just the part after it."
    }

    /// Store the key. Returns whether it actually landed.
    ///
    /// The status from both keychain calls used to be discarded, so a refused
    /// write reported exactly like a successful one and the next run failed
    /// with an authentication error pointing nowhere near the real cause
    /// (#112). A save that silently does nothing is worse than one that fails
    /// loudly, because the person has no reason to try again.
    /// The two keychain calls a save makes, injectable so a test can exercise
    /// the status handling without writing to the real login keychain.
    ///
    /// This seam is not decoration. KeychainStore reads and writes the login
    /// keychain under the same service and account the shipping app uses, so a
    /// test that saved and deleted for real would overwrite Dan's actual API
    /// key, and an unsigned test bundle touching it raises a system permission
    /// dialog that blocks the whole run. Both happened on 2026-08-09. Tests
    /// must be structurally unable to reach live data (L2), so they inject.
    struct Writer {
        var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd

        init(update: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
             add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd) {
            self.update = update
            self.add = add
        }
    }

    @discardableResult
    static func saveAPIKey(_ key: String, using writer: Writer = Writer()) -> Bool {
        let cleaned = sanitize(key)
        guard let data = cleaned.data(using: .utf8) else { return false }
        // Try update first, then add
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = writer.update(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        // Only "no such item yet" justifies adding. Any other failure is a
        // real refusal and must be reported, not retried as an insert.
        guard status == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData] = data
        return writer.add(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
