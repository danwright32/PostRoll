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

    static func saveAPIKey(_ key: String) {
        let cleaned = sanitize(key)
        let data = cleaned.data(using: .utf8)!
        // Try update first, then add
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
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
