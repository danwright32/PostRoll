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

    /// A key of the length a real one actually is. The old value here was
    /// nineteen characters and was called "a full key", which is how the
    /// missing length check in #348 stayed invisible: the test that was
    /// supposed to prove a whole key is accepted was itself asserting on a
    /// truncated one.
    static let realisticKey = "sk-ant-api03-" + String(repeating: "A", count: 95)

    func testAFullKeyIsAccepted() {
        XCTAssertEqual(Self.realisticKey.count, 108, "the sample is not key sized")
        XCTAssertNil(KeychainStore.formatWarning(for: Self.realisticKey))
    }

    // MARK: - #348: the right shape at the wrong length is still not a key

    func testATruncatedKeyIsRefusedEvenThoughThePrefixIsRight() {
        // The exact value that sat stored on Dan's Mac from 2026-08-09: the
        // prefix was right, so nothing complained, and the metered path had
        // never once run.
        let warning = KeychainStore.formatWarning(for: "sk-ant-abc123")

        XCTAssertNotNil(warning, "thirteen characters passed as a whole key")
        XCTAssertTrue(warning!.contains("108"),
                      "the message does not say how long a real key is: \(warning ?? "nil")")
    }

    func testTheMessageSaysHowLongWhatWasPastedIs() {
        // Naming the number is what lets a person see they pasted part of it,
        // without the key itself ever being echoed.
        let warning = KeychainStore.formatWarning(for: "sk-ant-abc123") ?? ""

        XCTAssertTrue(warning.contains("13"), "got: \(warning)")
        XCTAssertFalse(warning.contains("abc123"), "the message echoes the key: \(warning)")
    }

    func testATruncatedKeyCannotBeSaved() {
        // L67: code that has already detected the value is wrong must block the
        // action, not merely label it. A warning beside an enabled button is
        // how this shipped and sat unnoticed for two days.
        XCTAssertFalse(KeychainStore.isSavable("sk-ant-abc123"))
        XCTAssertTrue(KeychainStore.isSavable(Self.realisticKey))
    }

    func testClearingTheKeyIsStillAllowed() {
        // Empty means "forget the stored key", which must not be caught by a
        // length rule aimed at truncation.
        XCTAssertTrue(KeychainStore.isSavable(""))
        XCTAssertTrue(KeychainStore.isSavable("   "))
    }

    func testTheMinimumIsBelowARealKeyAndFarAboveATruncation() {
        // Guards the constant itself. Set at or above 108 it would refuse real
        // keys; set near 13 it would admit the value this issue is about.
        XCTAssertLessThan(KeychainStore.minimumKeyLength, 108)
        XCTAssertGreaterThan(KeychainStore.minimumKeyLength, 20)
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
        XCTAssertNil(KeychainStore.formatWarning(for: "  " + Self.realisticKey + "\n"))
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

    /// Every case below injects the two keychain calls, so nothing here can
    /// reach the real login keychain. Writing there for real would overwrite
    /// the live API key and raise a system permission dialog that blocks the
    /// run, which is exactly what happened before this seam existed.

    private func writer(update: OSStatus, add: OSStatus = errSecSuccess) -> KeychainStore.Writer {
        KeychainStore.Writer(update: { _, _ in update }, add: { _, _ in add })
    }

    func testAnUpdateThatSucceedsReportsSuccess() {
        XCTAssertTrue(KeychainStore.saveAPIKey(
            "sk-ant-abc", using: writer(update: errSecSuccess)))
    }

    func testAFirstTimeSaveFallsBackToAddingAndReportsSuccess() {
        // No entry yet is the ordinary first-run case, not a failure.
        XCTAssertTrue(KeychainStore.saveAPIKey(
            "sk-ant-abc", using: writer(update: errSecItemNotFound, add: errSecSuccess)))
    }

    func testARefusedWriteIsReportedAsAFailure() {
        // The defect: this used to report exactly like a successful save, so
        // the next run failed with an authentication error pointing nowhere
        // near the real cause.
        XCTAssertFalse(KeychainStore.saveAPIKey(
            "sk-ant-abc", using: writer(update: errSecAuthFailed)))
    }

    func testAFailedAddIsReportedAsAFailure() {
        XCTAssertFalse(KeychainStore.saveAPIKey(
            "sk-ant-abc", using: writer(update: errSecItemNotFound, add: errSecAuthFailed)))
    }

    func testAnUnexpectedUpdateErrorIsNotRetriedAsAnAdd() {
        // Only "no such item yet" justifies inserting. Treating any failure as
        // a reason to add would turn a permissions refusal into a second write
        // attempt and report whatever that happened to return.
        var addCalled = false
        let probe = KeychainStore.Writer(
            update: { _, _ in errSecAuthFailed },
            add: { _, _ in addCalled = true; return errSecSuccess })

        XCTAssertFalse(KeychainStore.saveAPIKey("sk-ant-abc", using: probe))
        XCTAssertFalse(addCalled, "a refused update must not fall through to an insert")
    }

    func testTheKeyIsSanitizedBeforeItIsWritten() {
        // The whole point of sanitize: a trailing newline from a copy-paste
        // must never reach the keychain.
        var written: String?
        let probe = KeychainStore.Writer(
            update: { _, attrs in
                let dict = attrs as! [CFString: Any]
                if let data = dict[kSecValueData] as? Data {
                    written = String(data: data, encoding: .utf8)
                }
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess })

        _ = KeychainStore.saveAPIKey("  sk-ant-abc\n", using: probe)

        XCTAssertEqual(written, "sk-ant-abc")
    }
}
