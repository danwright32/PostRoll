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
        XCTAssertNil(KeychainStore.warning(for: .anthropic, typed: Self.realisticKey))
    }

    // MARK: - #348: the right shape at the wrong length is still not a key

    func testATruncatedKeyIsRefusedEvenThoughThePrefixIsRight() {
        // The exact value that sat stored on Dan's Mac from 2026-08-09: the
        // prefix was right, so nothing complained, and the metered path had
        // never once run.
        let warning = KeychainStore.warning(for: .anthropic, typed: "sk-ant-abc123")

        XCTAssertNotNil(warning, "thirteen characters passed as a whole key")
        XCTAssertTrue(warning!.contains("108"),
                      "the message does not say how long a real key is: \(warning ?? "nil")")
    }

    func testTheMessageSaysHowLongWhatWasPastedIs() {
        // Naming the number is what lets a person see they pasted part of it,
        // without the key itself ever being echoed.
        let warning = KeychainStore.warning(for: .anthropic, typed: "sk-ant-abc123") ?? ""

        XCTAssertTrue(warning.contains("13"), "got: \(warning)")
        XCTAssertFalse(warning.contains("abc123"), "the message echoes the key: \(warning)")
    }

    func testATruncatedKeyCannotBeSaved() {
        // L67: code that has already detected the value is wrong must block the
        // action, not merely label it. A warning beside an enabled button is
        // how this shipped and sat unnoticed for two days.
        XCTAssertFalse(KeychainStore.isSavable(secret: .anthropic, "sk-ant-abc123"))
        XCTAssertTrue(KeychainStore.isSavable(secret: .anthropic, Self.realisticKey))
    }

    func testClearingTheKeyIsStillAllowed() {
        // Empty means "forget the stored key", which must not be caught by a
        // length rule aimed at truncation.
        XCTAssertTrue(KeychainStore.isSavable(secret: .anthropic, ""))
        XCTAssertTrue(KeychainStore.isSavable(secret: .anthropic, "   "))
    }

    func testTheMinimumIsBelowARealKeyAndFarAboveATruncation() {
        // Guards the constant itself. Set at or above 108 it would refuse real
        // keys; set near 13 it would admit the value this issue is about.
        XCTAssertLessThan(KeychainStore.Secret.anthropic.minimumLength, 108)
        XCTAssertGreaterThan(KeychainStore.Secret.anthropic.minimumLength, 20)
    }

    func testAKeyPastedWithoutThePrefixIsCalledOut() {
        // Dan read the placeholder as the field already accounting for the
        // prefix and pasted only the part after it. That produced the same
        // "invalid x-api-key" as a genuinely wrong key, with nothing to say
        // which of the two had happened.
        let warning = KeychainStore.warning(for: .anthropic, typed: "api03-abc123")

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("sk-ant-"), "got: \(warning ?? "nil")")
    }

    func testAnEmptyFieldIsNotAWarning() {
        // Empty means "clear the key", which is a legitimate action, not a
        // formatting mistake.
        XCTAssertNil(KeychainStore.warning(for: .anthropic, typed: ""))
        XCTAssertNil(KeychainStore.warning(for: .anthropic, typed: "   "))
    }

    func testTheCheckIgnoresSurroundingWhitespace() {
        // A key copied from a browser commonly carries a trailing newline, and
        // that must not be reported as a missing prefix.
        XCTAssertNil(KeychainStore.warning(for: .anthropic, typed: "  " + Self.realisticKey + "\n"))
    }

    func testTheWarningDoesNotBlockSaving() {
        // It is a warning, not a gate: the prefix is a strong convention, not
        // something worth refusing a key over if the format ever changes.
        XCTAssertFalse(KeychainStore.warning(for: .anthropic, typed: "nope") == nil)
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
        XCTAssertTrue(KeychainStore.save("sk-ant-abc", for: .anthropic,
                           using: writer(update: errSecSuccess)))
    }

    func testAFirstTimeSaveFallsBackToAddingAndReportsSuccess() {
        // No entry yet is the ordinary first-run case, not a failure.
        XCTAssertTrue(KeychainStore.save("sk-ant-abc", for: .anthropic,
                           using: writer(update: errSecItemNotFound, add: errSecSuccess)))
    }

    func testARefusedWriteIsReportedAsAFailure() {
        // The defect: this used to report exactly like a successful save, so
        // the next run failed with an authentication error pointing nowhere
        // near the real cause.
        XCTAssertFalse(KeychainStore.save("sk-ant-abc", for: .anthropic,
                            using: writer(update: errSecAuthFailed)))
    }

    func testAFailedAddIsReportedAsAFailure() {
        XCTAssertFalse(KeychainStore.save("sk-ant-abc", for: .anthropic,
                            using: writer(update: errSecItemNotFound, add: errSecAuthFailed)))
    }

    func testAnUnexpectedUpdateErrorIsNotRetriedAsAnAdd() {
        // Only "no such item yet" justifies inserting. Treating any failure as
        // a reason to add would turn a permissions refusal into a second write
        // attempt and report whatever that happened to return.
        var addCalled = false
        let probe = KeychainStore.Writer(
            update: { _, _ in errSecAuthFailed },
            add: { _, _ in addCalled = true; return errSecSuccess })

        XCTAssertFalse(KeychainStore.save("sk-ant-abc", for: .anthropic, using: probe))
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

        _ = KeychainStore.save("  sk-ant-abc\n", for: .anthropic, using: probe)

        XCTAssertEqual(written, "sk-ant-abc")
    }

    // MARK: - #448: a refused DELETE must not report as gone

    /// The unswept twin of #112. `saveAPIKey` reports a refusal; the delete
    /// threw its status away, so Settings flipped to the green Saved state
    /// while the key was still in the keychain and the next run kept billing
    /// against it (L12, L30).

    func testAnAcceptedDeleteReportsSuccess() {
        let probe = KeychainStore.Deleter(delete: { _ in errSecSuccess })

        XCTAssertTrue(KeychainStore.delete(.anthropic, using: probe))
    }

    /// Nothing there to remove is the state the caller asked for, so it is a
    /// success rather than a failure to report.
    func testNoKeyStoredCountsAsRemoved() {
        let probe = KeychainStore.Deleter(delete: { _ in errSecItemNotFound })

        XCTAssertTrue(KeychainStore.delete(.anthropic, using: probe))
    }

    func testARefusedDeleteIsReportedRatherThanReadingAsGone() {
        let probe = KeychainStore.Deleter(delete: { _ in errSecAuthFailed })

        XCTAssertFalse(KeychainStore.delete(.anthropic, using: probe),
                       "a refused delete reported as done, so the key is still "
                       + "stored while the screen says it is not")
    }

    // MARK: - A second secret, described rather than hard wired (#1002)

    /// KeychainStore bound ONE account through `service`, `readAPIKey`,
    /// `saveAPIKey`, `deleteAPIKey`, `Writer`, `Deleter` and two default
    /// closures. The Meta system user token measured 199 characters starting
    /// `EAA`, so before this every one of those paths would have written it
    /// over the Anthropic key, and the warning beside the field would have told
    /// Dan a perfectly good token "does not start with sk-ant-" while Save
    /// stayed live.

    /// The real thing, measured on 2026-09-01. Not a made up string: the
    /// length is the whole point of the minimum below.
    private static let realisticMetaToken = "EAA" + String(repeating: "x", count: 196)

    func testTheTwoSecretsAreStoredUnderDifferentAccounts() {
        // The one property that makes a second secret safe at all. Sharing an
        // account name would have each save silently overwrite the other, and
        // the symptom would be an authentication failure in whichever feature
        // was used second.
        XCTAssertNotEqual(KeychainStore.Secret.anthropic.account,
                          KeychainStore.Secret.meta.account)
    }

    func testAWholeMetaTokenIsAccepted() {
        XCTAssertNil(KeychainStore.warning(for: .meta, typed: Self.realisticMetaToken))
        XCTAssertTrue(KeychainStore.isSavable(secret: .meta, Self.realisticMetaToken))
    }

    func testAGoodMetaTokenIsNotToldItShouldStartWithTheAnthropicPrefix() {
        // The defect this descriptor exists to prevent, stated as its own
        // assertion: one warning function reading one hard wired prefix tells
        // the person the wrong thing about the right value.
        let warning = KeychainStore.warning(for: .meta, typed: Self.realisticMetaToken)

        XCTAssertNil(warning, "a correct Meta token was called malformed: \(warning ?? "")")
    }

    func testATruncatedMetaTokenIsRefusedAtThePaste() {
        // A prefix check alone passes this: it starts EAA and is obviously
        // part of a token. Length is what catches the commoner accident.
        let partial = "EAAxxxxxxxxxx"

        XCTAssertNotNil(KeychainStore.warning(for: .meta, typed: partial))
        XCTAssertFalse(KeychainStore.isSavable(secret: .meta, partial),
                       "a partial token must be blocked, not merely labelled (#348)")
    }

    func testAMetaTokenPastedWithoutItsPrefixIsCalledOut() {
        let warning = KeychainStore.warning(for: .meta,
                                            typed: String(repeating: "x", count: 199)) ?? ""

        XCTAssertTrue(warning.contains("EAA"), warning)
        XCTAssertFalse(warning.contains("sk-ant-"),
                       "the Anthropic prefix has no business in a Meta warning: \(warning)")
    }

    func testEachSecretsMinimumSitsBelowARealOneAndAboveATruncation() {
        // The same rule the Anthropic key already had, applied per secret
        // rather than shared: a real Meta token is 199 characters and the
        // Explorer token measured on 2026-08-29 was 302, so a minimum set from
        // either would refuse the other.
        XCTAssertLessThan(KeychainStore.Secret.meta.minimumLength, 199)
        XCTAssertGreaterThan(KeychainStore.Secret.meta.minimumLength, 20)
    }

    func testSavingTheMetaTokenWritesUnderTheMetaAccount() {
        // Built is not wired (L3). A descriptor the write path ignores would
        // leave every one of the assertions above correct and the token in the
        // Anthropic slot.
        var account: String?
        let probe = KeychainStore.Writer(
            update: { query, _ in
                account = (query as! [CFString: Any])[kSecAttrAccount] as? String
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess })

        _ = KeychainStore.save(Self.realisticMetaToken, for: .meta, using: probe)

        XCTAssertEqual(account, KeychainStore.Secret.meta.account)
        XCTAssertNotEqual(account, KeychainStore.Secret.anthropic.account)
    }

    func testDeletingOneSecretNamesThatSecretsAccount() {
        var account: String?
        let probe = KeychainStore.Deleter(delete: { query in
            account = (query as! [CFString: Any])[kSecAttrAccount] as? String
            return errSecSuccess
        })

        _ = KeychainStore.delete(.meta, using: probe)

        XCTAssertEqual(account, KeychainStore.Secret.meta.account)
    }

    func testTheSettingsScreenDrawsBothFieldsFromTheDescriptors() {
        // The field, its placeholder, its warning and its header all come from
        // the Secret, so a second secret cannot be added by copying the block
        // and editing the strings, which is how the prefix got hard wired in
        // the first place.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent("Sources/Views/SettingsView.swift")
        let code = SwiftSourceText.withoutComments(
            try! String(contentsOf: source, encoding: .utf8))

        XCTAssertFalse(code.contains("sk-ant-"),
                       "the Anthropic prefix is typed into the settings screen rather "
                       + "than read from the secret it belongs to")
        XCTAssertTrue(code.contains("SecretField(secret: .anthropic"),
                      "the Anthropic key is not drawn from its descriptor")
        XCTAssertTrue(code.contains("SecretField(secret: .meta"),
                      "the Meta token has no field on the settings screen, so there is "
                      + "nowhere to put it and the fetch can never be given one")
    }

    func testTheDeleteActuallyAsksForTheAppsOwnItem() {
        // A query that named nothing in particular would delete whatever it
        // matched, or nothing at all, and report the same either way.
        var query: [CFString: Any]?
        let probe = KeychainStore.Deleter(delete: { q in
            query = (q as! [CFString: Any])
            return errSecSuccess
        })

        _ = KeychainStore.delete(.anthropic, using: probe)

        XCTAssertEqual(query?[kSecClass] as! CFString?, kSecClassGenericPassword)
        XCTAssertNotNil(query?[kSecAttrService])
        XCTAssertNotNil(query?[kSecAttrAccount])
    }
}
