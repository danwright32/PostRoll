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

    /// The keychain refused to remove the key (#448).
    ///
    /// Says the key is still there, because that is the part that costs money:
    /// the next run keeps using it. Distinct from a refused SAVE, which leaves
    /// the previous key in place instead (L11).
    static let keyNotRemoved =
        "The key could not be removed from your keychain. It is still stored, "
        + "so generation will keep using it. Check Keychain Access, then try again."
}
