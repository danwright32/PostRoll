import Foundation
import Security

/// Keychain storage for the secrets the app holds, one descriptor each.
///
/// This bound exactly ONE account until #1002, through `service`, the
/// functions, `Writer`, `Deleter` and two default closures. A second secret
/// added by copying that shape would have written over the first, and the
/// warning beside the field would have told Dan a perfectly good Meta token
/// "does not start with sk-ant-" while Save stayed live.
///
/// So the parts that differ per secret are DESCRIBED rather than hard wired,
/// and every function takes the secret it is acting on. The parameter carries
/// no default: a default standing for "the usual one" is how a caller that
/// forgot it silently reads or overwrites somebody else's credential, and a
/// wrong secret fails as an authentication error pointing nowhere near its
/// cause (L168).
enum KeychainStore {
    private static let service = "com.dwphotony.PostRoll"

    /// One secret the app stores, and everything that differs about it.
    struct Secret: Equatable, Sendable {
        /// The keychain account name. Distinct per secret, which is the one
        /// property that makes holding two of them safe.
        let account: String
        /// What to call it on screen, in a sentence.
        let name: String
        /// The prefix every whole value carries.
        let prefix: String
        /// The shortest thing that could still be a whole value (#348).
        let minimumLength: Int
        /// Roughly how long a real one is, for the warning's wording. Named
        /// per secret because the two differ by nearly a factor of two.
        let typicalLength: Int
        /// What the empty field says.
        let placeholder: String
        /// The section heading above the field.
        let heading: String

        /// The Anthropic API key. A real one measures 108 characters; the bar
        /// sits well below that so a format change does not start refusing
        /// valid keys, and far above a truncation so it cannot admit one: the
        /// value that sat stored on this Mac for two days was thirteen
        /// characters, prefix intact.
        static let anthropic = Secret(
            account: "ANTHROPIC_API_KEY",
            name: "Anthropic API key",
            prefix: "sk-ant-",
            minimumLength: 40,
            typicalLength: 108,
            placeholder: "Paste the whole key, starting sk-ant-",
            heading: "Anthropic API Key")

        /// The Meta system user token the account figures are read with.
        ///
        /// MEASURED on 2026-09-01: 199 characters, starting `EAA`. The token
        /// used for the 2026-08-29 probe was 302, but that was an Explorer
        /// token, which is a different kind and is not what ships. A minimum
        /// derived from either measurement alone would refuse the other, so it
        /// sits at 80: comfortably under the shorter real one and far above
        /// any partial paste. See docs/META-APP.md.
        static let meta = Secret(
            account: "META_SYSTEM_USER_TOKEN",
            name: "Meta system user token",
            prefix: "EAA",
            minimumLength: 80,
            typicalLength: 199,
            placeholder: "Paste the whole token, starting EAA",
            heading: "Meta System User Token")
    }

    static func read(_ secret: Secret) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      secret.account,
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

    /// Whether this value can be stored at all.
    ///
    /// Empty is savable and means forget the stored value, which is a
    /// legitimate action rather than a malformed one. Anything else has to be
    /// long enough to be a whole one: code that has already worked out the
    /// value is wrong must block the action rather than label it and leave the
    /// button live, which is how #348 shipped and went unnoticed.
    ///
    /// A prefix check alone catches the person who pasted only the part AFTER
    /// the prefix. It cannot catch the person who pasted most of a value, which
    /// is the commoner accident and the one that looks exactly like success.
    static func isSavable(secret: Secret, _ raw: String) -> Bool {
        let cleaned = sanitize(raw)
        return cleaned.isEmpty || cleaned.count >= secret.minimumLength
    }

    /// Whether pressing Save would do anything (#348, #935).
    ///
    /// `stored` is what the keychain held when it was last read, passed in
    /// rather than fetched. This rule used to live inline in the view's
    /// `.disabled(...)` modifier with a `readAPIKey()` inside it, so a
    /// privileged keychain call ran on every render pass of the Settings
    /// screen: typing one character into the field re-read the stored key.
    ///
    /// Both halves matter and they refuse for different reasons. Unchanged
    /// means there is nothing to write, and a live button there reports Saved
    /// for a write that changed nothing. Not savable means the value is too
    /// short to be a whole key, which is #348: code that has already worked out
    /// the value is wrong must block the action rather than label it and leave
    /// the button live. The warning beside the field says which, so a disabled
    /// button is never unexplained.
    ///
    /// Compared on the SANITISED value, because the field is a paste target and
    /// a pasted key routinely carries a trailing newline: a stray space would
    /// otherwise make an unchanged key look like a new one.
    static func canSave(secret: Secret, typed: String, stored: String) -> Bool {
        sanitize(typed) != stored && isSavable(secret: secret, typed)
    }

    /// What a press of Save did, and what the screen holds afterwards (#935).
    struct SaveOutcome: Equatable {
        /// What the store holds now, as far as anything can tell.
        var stored: String
        /// Whether to show the Saved mark. Only ever true for a write that
        /// landed: a refused write reporting as a successful one is #112.
        var saved: Bool
        /// Why not, when not. Distinct per refusal, because a refused save and
        /// a refused delete leave the machine in different states and need
        /// different remedies (L11).
        var error: String?
    }

    /// Carry out the write the typed value asks for, and say what is left.
    ///
    /// Pulled out of the button's action so every branch can be exercised with
    /// no keychain at all (#935). The screen now HOLDS the stored key rather
    /// than re-reading it on each render, and that is only safe while the value
    /// moves at exactly the right moments: a refused write must leave it alone,
    /// or the screen reports a key the keychain does not hold and the button
    /// offering the retry is the one reading it (L95).
    ///
    /// An empty value means remove the key, which is a real action and the only
    /// way to perform it, rather than a malformed one.
    ///
    /// The writers are parameters so a test can refuse without a keychain, and
    /// they default to the real ones so no call site can accidentally get a
    /// fake: a seam whose default became the test double would leave the app
    /// writing nowhere (L196).
    static func save(secret: Secret,
                     typed: String,
                     stored: String,
                     write: ((String) -> Bool)? = nil,
                     remove: (() -> Bool)? = nil) -> SaveOutcome {
        // Defaulted here rather than in the signature so the real writers are
        // bound to THIS secret. A default closure in the parameter list cannot
        // see the argument beside it, which is how a per secret store ends up
        // writing every secret to one account.
        let write = write ?? { save($0, for: secret) }
        let remove = remove ?? { delete(secret) }
        let trimmed = sanitize(typed)

        if trimmed.isEmpty {
            guard remove() else {
                return SaveOutcome(stored: stored, saved: false,
                                   error: SettingsCopy.keyNotRemoved)
            }
            return SaveOutcome(stored: "", saved: true, error: nil)
        }

        guard write(trimmed) else {
            return SaveOutcome(stored: stored, saved: false,
                               error: SettingsCopy.keyNotSaved)
        }
        // The SANITISED value, which is what was written. Storing what was typed
        // would leave the screen holding a value with a newline on it that the
        // keychain does not have, so the button would stay live for ever (#128).
        return SaveOutcome(stored: trimmed, saved: true, error: nil)
    }

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
    static func warning(for secret: Secret, typed raw: String) -> String? {
        let cleaned = sanitize(raw)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.hasPrefix(secret.prefix) else {
            return "This does not start with \(secret.prefix). Paste the WHOLE "
                 + "value, including the \(secret.prefix) at the front, not just "
                 + "the part after it."
        }
        guard cleaned.count >= secret.minimumLength else {
            // The count, never the value: this message is shown on screen and
            // the secret must not be echoed anywhere.
            return "This is only \(cleaned.count) characters. A whole "
                 + "\(secret.name) is about \(secret.typicalLength), so this looks "
                 + "like part of one. Copy it again and check the whole thing "
                 + "came across."
        }
        return nil
    }

    /// Store one secret under its own account. Returns whether it landed.
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
    static func save(_ value: String, for secret: Secret,
                     using writer: Writer = Writer()) -> Bool {
        let cleaned = sanitize(value)
        guard let data = cleaned.data(using: .utf8) else { return false }
        // Try update first, then add
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: secret.account,
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

    /// The one keychain call a delete makes, injectable for the same reason
    /// `Writer` is: a test that deleted for real would remove Dan's actual API
    /// key (L2).
    struct Deleter {
        var delete: (CFDictionary) -> OSStatus = SecItemDelete

        init(delete: @escaping (CFDictionary) -> OSStatus = SecItemDelete) {
            self.delete = delete
        }
    }

    /// Removes one stored secret. Returns whether it is genuinely gone.
    ///
    /// The status used to be discarded, so Settings flipped to Saved whatever
    /// happened, and a keychain that refused the delete left the key stored
    /// while the screen said it was not, with the next run still billing
    /// against it. That is the shape #112 fixed for the save and this is
    /// its unswept twin (#448, L12, L30).
    ///
    /// Nothing stored counts as removed: that is the state the caller asked
    /// for, and reporting it as a failure would be a distinct cause getting
    /// the wrong message (L11).
    @discardableResult
    static func delete(_ secret: Secret, using deleter: Deleter = Deleter()) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: secret.account,
        ]
        let status = deleter.delete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
