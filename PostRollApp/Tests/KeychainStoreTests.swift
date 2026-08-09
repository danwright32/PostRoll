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

    // MARK: - #128: a key pasted without its prefix must not look like a bad key

    func testAFullKeyIsAccepted() {
        XCTAssertNil(KeychainStore.formatWarning(for: "sk-ant-api03-abc123"))
    }

    func testAKeyPastedWithoutThePrefixIsCalledOut() {
        // Dan read the placeholder as the field already accounting for the
        // prefix and pasted only the part after it. That produced the same
        // "invalid x-api-key" as a genuinely wrong key, with nothing to say
        // which of the two had happened.
        let warning = KeychainStore.formatWarning(for: "api03-abc123")

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("sk-ant-"), "got: \(warning ?? "nil")")
    }

    func testAnEmptyFieldIsNotAWarning() {
        // Empty means "clear the key", which is a legitimate action, not a
        // formatting mistake.
        XCTAssertNil(KeychainStore.formatWarning(for: ""))
        XCTAssertNil(KeychainStore.formatWarning(for: "   "))
    }

    func testTheCheckIgnoresSurroundingWhitespace() {
        // A key copied from a browser commonly carries a trailing newline, and
        // that must not be reported as a missing prefix.
        XCTAssertNil(KeychainStore.formatWarning(for: "  sk-ant-api03-abc\n"))
    }

    func testTheWarningDoesNotBlockSaving() {
        // It is a warning, not a gate: the prefix is a strong convention, not
        // something worth refusing a key over if the format ever changes.
        XCTAssertFalse(KeychainStore.formatWarning(for: "nope") == nil)
        XCTAssertEqual(KeychainStore.sanitize(" nope "), "nope")
    }

    // MARK: - #112: a failed save must not look successful
    //
    // Deliberately NOT covered by a round trip against the real keychain.
    // KeychainStore reads and writes the login keychain under the same service
    // and account the shipping app uses, so a test that saved and deleted here
    // would overwrite Dan's actual API key, and an unsigned test bundle
    // touching it raises a system permission dialog that blocks the whole run
    // (both of which happened, 2026-08-09).
    //
    // Proving the status is honoured needs a seam that lets a test stand in for
    // SecItemUpdate/SecItemAdd. Tracked separately; the fix itself (returning
    // whether the write landed, and the Settings screen reporting it) ships
    // without that cover rather than with cover that damages real data (L2).
}
