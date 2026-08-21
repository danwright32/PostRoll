import XCTest

/// Scratch directories that clean themselves up (#781).
///
/// The suite writes into the per-user temp folder, and macOS clears that only
/// at boot, so anything left behind accumulates for as long as the machine
/// stays up. Measured on 2026-08-21 across a seven day uptime: 161 stray
/// `accounts-*.json.*.bak` files, about 23 a day.
///
/// ## Why it hands out DIRECTORIES rather than files
///
/// This is why the leak was invisible. `ExportTagStampTests` created one file
/// and removed one file, so counting cleanups against creations reported it
/// balanced. What survived was a rotating BACKUP the code under test wrote
/// BESIDE that file, which the test never named and therefore never removed.
///
/// A directory takes with it whatever the code under test decided to put in it,
/// named or not. Counting `createDirectory` calls against `defer` blocks is the
/// measurement that misses this; what survives a real run is the one that does
/// not.
///
/// ## Why this is an extension and not a held object
///
/// The reference implementation this came from (danwright32/downbeat, 866e82c)
/// is a type held as a property whose `deinit` does the removal, which works
/// because Swift Testing builds and releases a suite instance per test.
///
/// XCTest does not: it holds every test case instance for the length of the
/// run, so `deinit` fires at process exit if at all. Measured here before this
/// was rewritten: the backup files stopped leaking and six sandbox directories
/// leaked in their place, one per test.
///
/// `addTeardownBlock` is XCTest's own per-test teardown. It runs whether the
/// test passed or threw, and registering it INSIDE the helper is what keeps it
/// off the call site, which is the property that mattered about the original: a
/// rule every future test has to remember is a rule that gets forgotten (L27).
extension XCTestCase {

    /// A fresh empty directory, removed when this test ends.
    func temporarySandbox(_ label: String = "sandbox") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A path inside a fresh sandbox, for code that creates the file itself.
    /// Whatever it writes alongside goes with the directory.
    func temporaryFile(named name: String, in label: String = "sandbox") -> URL {
        temporarySandbox(label).appendingPathComponent(name)
    }
}
