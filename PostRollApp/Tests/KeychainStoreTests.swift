import XCTest

/// Pins the API key sanitization contract. `SettingsView`'s Save button
/// used `.trimmingCharacters(in: .whitespaces)`, which strips spaces and
/// tabs but NOT newlines. A key copied from a browser or terminal commonly
/// carries a trailing line break; that corrupted value got saved to the
/// Keychain as-is, so every Anthropic API call failed with "invalid
/// x-api-key" even after replacing the key with a freshly generated one.
final class KeychainStoreTests: XCTestCase {

    func testSanitizeStripsTrailingNewline() {
        XCTAssertEqual(KeychainStore.sanitize("sk-ant-abc123\n"), "sk-ant-abc123")
    }

    func testSanitizeStripsLeadingAndTrailingWhitespaceAndNewlines() {
        XCTAssertEqual(KeychainStore.sanitize("  \nsk-ant-abc123\n\n  "), "sk-ant-abc123")
    }

    func testSanitizeStripsCarriageReturn() {
        XCTAssertEqual(KeychainStore.sanitize("sk-ant-abc123\r\n"), "sk-ant-abc123")
    }

    func testSanitizeLeavesCleanKeyUnchanged() {
        XCTAssertEqual(KeychainStore.sanitize("sk-ant-abc123"), "sk-ant-abc123")
    }

    func testSanitizeDoesNotStripInternalWhitespace() {
        // A pasted key should never legitimately contain internal whitespace,
        // but sanitize() must not be more aggressive than trimming the ends.
        XCTAssertEqual(KeychainStore.sanitize("sk-ant abc123"), "sk-ant abc123")
    }
}
