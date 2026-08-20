import Foundation

/// Where this app's preferences live (#734, #738).
///
/// Eleven places named `UserDefaults.standard` inline, and four of them WROTE:
/// the hashtag store's `save`, the timing store's setter, the export folder
/// `ExportManager` remembers, and every write through `HandleBook.shared`. All
/// eleven are compiled into the test bundle, so a rendered screen picking up a
/// write would have edited Dan's real global tags, or the handle book he has
/// built up across every event he has shot, whose only copy is that book.
///
/// #722 and #727 closed this for the three stores that had an initializer to
/// compile out. The eight places that reached the same store with no
/// initializer to name were untouched, and nothing reported them: a rule keyed
/// on a list of stores only ever checks the stores somebody remembered to list
/// (L96). This is the domain itself, named once, with the live one compiled out
/// of the test bundle.
///
/// The per-store seams stay. `HandleBook(defaults:)`,
/// `PostingPresetStore(defaults:)` and `Event.effectivePostingPreset(in:)` are
/// how a test says what it wants READ; this is only what the app reaches for
/// when nobody said.
enum AppPreferences {

    #if POSTROLL_TESTS
    /// The suite the test bundle gets instead.
    ///
    /// Its own domain, so a suite Dan's app never opens holds whatever the
    /// tests write. One fixed name rather than a fresh one per run: a name per
    /// process would leave a plist behind for every run of the suite, and
    /// anything that cares which values it reads passes its own suite anyway.
    static let testSuiteName = "com.dwphotony.PostRoll.tests"

    nonisolated(unsafe) static let store: UserDefaults = {
        guard let scratch = UserDefaults(suiteName: testSuiteName) else {
            // Deliberately fatal. Falling back to `.standard` here would reach
            // the exact store this exists to keep the suite away from, and it
            // would do it silently, at the moment the safe store could not be
            // opened (L93, L173).
            fatalError("the test suite \(testSuiteName) could not be opened, and "
                       + "falling back to the live preferences is the one thing "
                       + "this must not do")
        }
        return scratch
    }()
    #else
    /// Dan's real preferences. Compiled out of the test bundle, so a test that
    /// reaches for the app's preferences gets the scratch suite above and there
    /// is no spelling of `.standard` for it to reach instead.
    /// `nonisolated(unsafe)` for the reason the other shared stores in this
    /// project carry it: UserDefaults is documented as thread safe, and the
    /// compiler cannot see that.
    nonisolated(unsafe) static let store = UserDefaults.standard
    #endif
}
