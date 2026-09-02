import XCTest

/// Whether the Save button on Settings can do anything (#348, #935).
///
/// The rule was written inline in the view's `.disabled(...)` modifier and one
/// of its two halves was a KEYCHAIN READ, so the stored key was fetched again on
/// every render pass of that screen: typing one character into the field
/// re-read it. A keychain read is a privileged call, not a cheap one. It can
/// prompt, it can be slow, and it should not be repeated to answer a comparison
/// that has not changed.
///
/// Nothing was wrong on screen, which is why it went unnoticed for as long as it
/// did, and why the fix has to be held to the behaviour rather than to the
/// saving: the disabled state is what TELLS you the value is unchanged, so it
/// has to stay correct after a save, after a delete, and after a write the
/// keychain refused (#112, #448).
///
/// A value taken by argument rather than a rule reaching for the store, so every
/// one of those transitions can be asserted without a keychain at all (L196).
final class SaveButtonStateTests: XCTestCase {

    private let whole = String(repeating: "k", count: 60)
    private let other = String(repeating: "j", count: 60)

    // MARK: - Nothing to do

    func testAValueMatchingWhatIsStoredCannotBeSaved() {
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: whole, stored: whole),
                       "the button is live with nothing to write, so pressing it "
                       + "reports Saved for a write that changed nothing")
    }

    func testWhitespaceAroundAnUnchangedValueIsStillUnchanged() {
        // The field is a paste target and a pasted key routinely carries a
        // trailing newline. Judged on the sanitised value, or a stray space
        // makes an unchanged key look like a new one.
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: "  \(whole)\n", stored: whole))
    }

    func testAnEmptyFieldOnAMachineWithNothingStoredCannotBeSaved() {
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: "", stored: ""),
                       "a first run offers a live Save button that would delete "
                       + "a key that is not there")
    }

    // MARK: - Something to do

    func testAWholeNewKeyCanBeSaved() {
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: whole, stored: ""))
    }

    func testReplacingOneKeyWithAnotherCanBeSaved() {
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: other, stored: whole))
    }

    func testClearingTheFieldWithAKeyStoredCanBeSaved() {
        // Empty means remove the stored key, which is a real action rather
        // than a malformed value, and the only way to perform it.
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: "", stored: whole))
    }

    // MARK: - Too short to be a whole key (#348)

    func testAPartialPasteCannotBeSavedEvenOverADifferentKey() {
        // The commonest accident, and the one that looks exactly like success:
        // most of a key, prefix intact. The warning beside the field says
        // which, so a disabled button here is never unexplained.
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: "sk-ant-abc", stored: whole))
    }

    func testAPartialPasteCannotBeSavedOnAnEmptyMachineEither() {
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: "sk-ant-abc", stored: ""))
    }

    // MARK: - The transitions the redraw read used to answer (#112, #448)

    func testAfterASaveThatLandedThereIsNothingLeftToDo() {
        // What the screen holds once a write succeeded: the stored value moves
        // up to the typed one, so the button falls quiet.
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: whole, stored: whole))
    }

    func testAfterADeleteThatLandedThereIsNothingLeftToDo() {
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: "", stored: ""))
    }

    func testAfterARefusedSaveTheButtonStaysLiveSoItCanBeRetried() {
        // The keychain said no, so nothing moved: what is stored is still the
        // old value and the typed one is still the new. A button that went
        // quiet here would leave the person facing a screen that says the write
        // failed and no way to try again (L109).
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: other, stored: whole))
    }

    func testAfterARefusedDeleteTheButtonStaysLiveSoItCanBeRetried() {
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: "", stored: whole))
    }

    // MARK: - What a press of Save leaves behind (#112, #448, #935)
    //
    // The rule above takes `stored` as a value, which says nothing about
    // whether the screen MOVES that value at the right moments. Holding the key
    // in state is only safe while a refused write leaves it alone, and that is
    // the half a pure rule cannot cover: it used to be answered by re-reading
    // the keychain, and dropping the read without covering it would be trading
    // a cost for a defect.
    //
    // The writers are handed in, so every branch runs with no keychain (L2).

    private func refusing() -> (write: (String) -> Bool, remove: () -> Bool) {
        ({ _ in false }, { false })
    }

    private func accepting() -> (write: (String) -> Bool, remove: () -> Bool) {
        ({ _ in true }, { true })
    }

    func testASaveThatLandedMovesWhatTheScreenBelievesIsStored() {
        let outcome = KeychainStore.save(secret: .anthropic, typed: "  \(other)\n", stored: whole,
                                         write: accepting().write,
                                         remove: accepting().remove)

        XCTAssertEqual(outcome.stored, other, "the sanitised value is what was "
                       + "written, so it is what the screen must now hold")
        XCTAssertTrue(outcome.saved)
        XCTAssertNil(outcome.error)
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: other, stored: outcome.stored),
                       "the button is still live after a save that landed")
    }

    func testASaveTheKeychainRefusedLeavesTheStoredValueAlone() {
        let outcome = KeychainStore.save(secret: .anthropic, typed: other, stored: whole,
                                         write: refusing().write,
                                         remove: refusing().remove)

        XCTAssertEqual(outcome.stored, whole, """
            a refused write moved what the screen believes is stored, so it now \
            reports a key the keychain does not hold, and the button that offers \
            the retry is the one reading it (#112, L95)
            """)
        XCTAssertFalse(outcome.saved, "a refused write reported as a successful one")
        XCTAssertNotNil(outcome.error)
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: other, stored: outcome.stored),
                      "the button went quiet after a refused save, so the screen "
                      + "says the write failed and offers no way to try again")
    }

    func testADeleteThatLandedLeavesNothingStored() {
        let outcome = KeychainStore.save(secret: .anthropic, typed: "", stored: whole,
                                         write: accepting().write,
                                         remove: accepting().remove)

        XCTAssertEqual(outcome.stored, "")
        XCTAssertTrue(outcome.saved)
        XCTAssertFalse(KeychainStore.canSave(secret: .anthropic, typed: "", stored: outcome.stored))
    }

    func testADeleteTheKeychainRefusedSaysTheKeyIsStillThere() {
        let outcome = KeychainStore.save(secret: .anthropic, typed: "", stored: whole,
                                         write: refusing().write,
                                         remove: refusing().remove)

        XCTAssertEqual(outcome.stored, whole)
        XCTAssertFalse(outcome.saved)
        // The two refusals need different sentences: one leaves the key in
        // place and costs money on every run, the other leaves the PREVIOUS
        // key in place (L11).
        XCTAssertEqual(outcome.error, SettingsCopy.keyNotRemoved)
        XCTAssertTrue(KeychainStore.canSave(secret: .anthropic, typed: "", stored: outcome.stored))
    }

    func testTheTwoRefusalsDoNotShareASentence() {
        let refusedSave = KeychainStore.save(secret: .anthropic, typed: other, stored: whole,
                                             write: refusing().write,
                                             remove: refusing().remove)
        let refusedDelete = KeychainStore.save(secret: .anthropic, typed: "", stored: whole,
                                               write: refusing().write,
                                               remove: refusing().remove)

        XCTAssertNotEqual(refusedSave.error, refusedDelete.error, """
            a refused save and a refused delete say the same thing. They leave \
            the machine in different states and need different remedies: one \
            keeps the OLD key, the other keeps the key you were trying to \
            remove and goes on billing for it (L11)
            """)
    }

    func testAValueIsWrittenSanitisedRatherThanAsTyped() {
        // What actually reached the keychain, not merely what was reported: a
        // trailing newline stored verbatim is the corruption #128 is about, and
        // every later call fails with a generic authentication error.
        var written: String?
        _ = KeychainStore.save(secret: .anthropic, typed: "  \(whole)\n", stored: "",
                               write: { written = $0; return true },
                               remove: { true })

        XCTAssertEqual(written, whole)
    }

    // MARK: - Where the store is actually read
    //
    // Everything above would pass unchanged with the view still reading the
    // keychain on every redraw, because a pure rule taking a value says nothing
    // about who calls it or how often. This is the half that closes #935, and
    // it can only be asked of the source: there is no way to count keychain
    // calls from a test bundle, and the screen builds its own state.

    /// The screen's source, with comment lines dropped so prose describing the
    /// read cannot satisfy a check counting them (L103).
    private func settingsViewCode() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/SettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("///") && !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheScreenReadsTheStoreExactlyOnce() throws {
        // One read, in the field's init. There are two fields now (#1002), and
        // that is exactly why this counts the CALL rather than the fields: a
        // second secret added by copying the block is how a read gets copied
        // into a body along with everything else.
        let code = try settingsViewCode()
        let reads = code.components(separatedBy: "source.read(").count - 1

        XCTAssertEqual(reads, 1, """
            SettingsView reads a stored secret \(reads) times. It has to be \
            exactly one, in SecretField's init: any read in a body runs on every \
            render pass, and a keychain read is a privileged call that can prompt \
            and can be slow. Hold the value in state and move it when a write \
            lands.
            """)
    }

    func testTheOnlyKeychainCallIsInsideTheSourceItself() throws {
        // The count above follows the SEAM, so it would miss a second route
        // that went straight to the store. `KeychainStore.read(secret)` belongs
        // in exactly one place, the KeySource enum's own `read(_:)`, which is what
        // makes the screen renderable at all (#918).
        let code = try settingsViewCode()
        let direct = code.components(separatedBy: "KeychainStore.read(secret)").count - 1
        XCTAssertEqual(direct, 1, """
            SettingsView names the keychain directly \(direct) times rather than \
            once. Every read goes through the KeySource, or a render points half \
            the screen at the real keychain.
            """)

        let start = try XCTUnwrap(code.range(of: "enum KeySource"))
        let end = try XCTUnwrap(code.range(of: "let keySource: KeySource"))
        XCTAssertTrue(code[start.lowerBound..<end.lowerBound]
                        .contains("KeychainStore.read(secret)"),
                      "the one keychain call is outside the KeySource enum, so "
                      + "the seam is not the only way the screen reaches the store")
    }

    func testTheOneReadHappensWhenTheScreenIsBuilt() throws {
        // A single read is not enough on its own: one read sitting in the body
        // is still one read per redraw, and this test would pass on it.
        let code = try settingsViewCode()
        let start = try XCTUnwrap(code.range(of: "init(secret: KeychainStore.Secret"),
                                  "SecretField no longer declares the init this "
                                  + "is about, so nothing here is being read")
        let end = try XCTUnwrap(code.range(of: "var body: some View", range:
                                           start.upperBound..<code.endIndex),
                                "SecretField has no body, so this is not the "
                                + "file this check was written against")
        let beforeTheBody = code[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(beforeTheBody.contains("source.read("), """
            the one read of the stored secret is not in init, so it happens while \
            the screen is being drawn rather than once when the field is built.
            """)
    }

    func testTheSaveButtonsDisabledStateDoesNotReachForTheStore() throws {
        // The exact line the issue is about, named rather than covered only by
        // the count above, so a read moving INTO it fails with the reason
        // rather than as an arithmetic surprise.
        //
        // Matched on `read(` rather than `read()`. This checked for the empty
        // parentheses, and when the read gained an argument (#1002) the guard
        // went on passing over a disabled state that really did reach for the
        // store: the mutation sweep reported it SURVIVED. A guard that pins the
        // exact rendering of a call rather than the rule behind it fails the
        // first legitimate refinement of that call (L103).
        //
        // Every `.disabled(` in the file, not the first one. There are two
        // secret fields now, so a check that stopped at the first would leave
        // the second exempt from the rule it exists to enforce.
        let code = try settingsViewCode()
        let modifiers = code.components(separatedBy: ".disabled(").dropFirst()

        XCTAssertFalse(modifiers.isEmpty,
                       "no Save button has a disabled state at all, so #348's block "
                       + "on a partial paste is gone")

        for modifier in modifiers {
            let scope = modifier.prefix(200)
            XCTAssertFalse(scope.contains("read("), """
                a disabled state reads the store again: \(scope). That modifier \
                runs on every render pass, which is the whole of #935.
                """)
        }
    }
}
