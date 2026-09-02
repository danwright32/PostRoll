import Foundation

/// Copy shown on the Settings screen that something other than the view needs
/// to be able to read.
///
/// Its own file rather than constants on `SettingsView`, because the test
/// target compiles a hand picked list of sources and a full SwiftUI view
/// cannot join it without dragging in the whole app. A string literal buried
/// in a view body is one nothing can assert against, which is how a link
/// silently stops being a link.
enum SettingsCopy {

    /// Where to get an API key. Named so the address shown in the copy and the
    /// place it actually sends you cannot drift apart.
    static let consoleURL = "https://console.anthropic.com"

    /// The API key footer, as markdown so the address is a real link.
    ///
    /// `Text(.init(...))` is what makes SwiftUI read the markdown. A typo in
    /// the brackets does not fail to build: it renders the raw markup as
    /// literal text, or leaves a plain address that looks clickable and is not,
    /// so `SettingsCopyTests` asserts the link survives edits to the wording.
    static let apiKeyFooter =
        "Used to call Claude directly, bypassing the CLI for faster generation. "
        + "Get a key at [console.anthropic.com](\(consoleURL))."

    /// The Meta token footer (#1002).
    ///
    /// Says what the token BUYS rather than what it is, because that is what
    /// decides whether it is worth setting up: without it every follower and
    /// engagement figure is typed in by hand, which is what the collaborator
    /// ranking ran on before this.
    ///
    /// Points at the document rather than repeating the steps. They involve a
    /// business portfolio, a system user and four permissions, and a shortened
    /// version here would be the version somebody follows and gets wrong.
    static let metaTokenFooter =
        "Reads follower, like and comment figures for the accounts you tag, so "
        + "the collaborator ranking does not need them typed in. Minting one "
        + "takes a few minutes in Meta's business settings: the steps are in "
        + "docs/META-APP.md."

    /// The keychain refused to remove the key (#448).
    ///
    /// Says the key is still there, because that is the part that costs money:
    /// the next run keeps using it. Distinct from a refused SAVE, which leaves
    /// the previous key in place instead (L11).
    static let keyNotRemoved =
        "The key could not be removed from your keychain. It is still stored, "
        + "so generation will keep using it. Check Keychain Access, then try again."

    /// The keychain refused to store the key (#112).
    ///
    /// Says what is still in force, because that is what decides what happens
    /// next: the previous key, if there is one, is what the next run uses. A
    /// refused write used to report exactly like a successful one, so the next
    /// run failed with an authentication error pointing nowhere near the cause.
    ///
    /// Beside its sibling above rather than written inline at the call site,
    /// which is where it used to live: two sentences about one pair of outcomes,
    /// kept apart, are two that can drift into saying the same thing.
    static let keyNotSaved =
        "The key could not be saved to your keychain. Nothing was stored, so "
        + "generation will keep using the previous key if there is one."
}
