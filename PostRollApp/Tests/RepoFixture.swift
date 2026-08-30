import XCTest

/// Reading a file out of the repo checkout, saying plainly when macOS is the
/// reason it could not (#271).
///
/// The repo lives under ~/Documents, which macOS protects, so the test process
/// needs Documents access to read its own fixtures. On one run that access was
/// refused and five fixture-reading suites went red at once with
/// `Operation not permitted`. The output read as five broken test suites, which
/// is not what it was.
///
/// That matters because `build-install.sh` runs the suite before installing to
/// /Applications. A gate that fails for reasons unrelated to the code teaches
/// the operator to pass SKIP_INSTALL_TESTS=1 every time, and a gate that is
/// always skipped is the same as no gate. So the failure has to name itself.
enum RepoFixture {

    /// The repo checkout, from this file's own location.
    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .deletingLastPathComponent()   // repo root
    }

    /// Why a fixture could not be read.
    enum Failure: Equatable {
        /// macOS refused access to the folder. Not a broken test.
        case permissionDenied(path: String)
        /// Genuinely not there, which usually IS a broken test or a bad path.
        case notFound(path: String)
        case other(path: String, description: String)

        /// What to print. The permission case says what it is and what to do,
        /// because the operator's next decision is whether bypassing the gate
        /// is safe, and here it is.
        var message: String {
            switch self {
            case .permissionDenied(let path):
                return """
                PERMISSIONS, not a test failure: macOS refused access to \(path).
                The repo lives under ~/Documents, which is protected, so the test \
                process needs Documents access to read its own fixtures. Grant it \
                under System Settings > Privacy & Security > Files and Folders (or \
                Full Disk Access) for Xcode and the test runner, then re-run. \
                Bypassing the install gate once with SKIP_INSTALL_TESTS=1 is safe \
                for this specific cause, because the code was never exercised \
                either way.
                """
            case .notFound(let path):
                return "fixture not found at \(path). The path is wrong, or the file "
                     + "was moved without updating the test that reads it."
            case .other(let path, let description):
                return "could not read \(path): \(description)"
            }
        }
    }

    /// Classify a read error. Public so the classification itself is testable
    /// against a real refused file rather than only asserted about.
    static func classify(_ error: Error, path: String) -> Failure {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
            return .permissionDenied(path: path)
        }
        if ns.domain == NSPOSIXErrorDomain,
           ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return .permissionDenied(path: path)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EACCES) || underlying.code == Int(EPERM) {
            return .permissionDenied(path: path)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError {
            return .notFound(path: path)
        }
        return .other(path: path, description: ns.localizedDescription)
    }

    /// Read a repo-relative fixture, failing with a message that names the
    /// cause rather than leaving the suite looking broken.
    static func data(_ relativePath: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = repoRoot(file: file).appendingPathComponent(relativePath)
        do {
            return try Data(contentsOf: url)
        } catch {
            let failure = classify(error, path: url.path)
            XCTFail(failure.message, file: file, line: line)
            throw error
        }
    }

    static func text(_ relativePath: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> String {
        String(decoding: try data(relativePath, file: file, line: line), as: UTF8.self)
    }

    // MARK: - Walking a source tree (#941)

    /// `url`'s path relative to `root`, or nil when it is not inside it.
    ///
    /// This exists because the obvious way to write it is wrong. Trimming
    /// `root.path + "/"` off the front of an absolute path is a SUBSTITUTION,
    /// and a substitution rewrites wherever it matches, not only the front. The
    /// two sides disagree the moment symlinks are involved: `#filePath` records
    /// the path a file was COMPILED from, an enumerator hands back a resolved
    /// one, and on macOS `/tmp` is a symlink to `/private/tmp`. Running the
    /// suite from a worktree under `/tmp` therefore trimmed nothing off the
    /// front, removed a match from the middle instead, and fused `/private`
    /// onto `AppState.swift` to make `privateAppState.swift`, a file nobody
    /// wrote (L251).
    ///
    /// So both sides are resolved first, and the comparison is over path
    /// COMPONENTS rather than over the text: a prefix that is not a whole
    /// component boundary cannot be mistaken for one, so a sibling directory
    /// named `Sources-old` is not read as being inside `Sources`.
    ///
    /// Nil rather than a best effort, because the caller can say what a file
    /// outside the root means for it, and a plausible looking name derived from
    /// whatever was left over is precisely the failure this replaces.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// Every file under `root` with `ext`, each with its path relative to it.
    ///
    /// The one way a source-scanning suite should walk the tree, so the
    /// resolving above happens once rather than at each sweep that needs it.
    ///
    /// A file the enumerator returns that does not come out as being under the
    /// root FAILS rather than being dropped: a walk that quietly discards what
    /// it cannot name reports a clean sweep over files it never read, which is
    /// indistinguishable from a sweep that found nothing wrong (L98, L215).
    static func files(under root: URL, withExtension ext: String,
                      file: StaticString = #filePath,
                      line: UInt = #line) -> [(relativePath: String, url: URL)] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard let walk = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil) else {
            XCTFail("could not read \(base.path), so nothing was swept",
                    file: file, line: line)
            return []
        }
        var found: [(relativePath: String, url: URL)] = []
        for case let url as URL in walk where url.pathExtension == ext {
            guard let relative = relativePath(of: url, under: base) else {
                XCTFail("\(url.path) came back from a walk of \(base.path) and is not "
                        + "inside it, so it cannot be named relatively and dropping it "
                        + "would leave this sweep silently short",
                        file: file, line: line)
                continue
            }
            found.append((relative, url))
        }
        return found
    }
}

#if POSTROLL_TESTS
extension CheckoutRevision {

    /// How long git gets when a TEST is the one waiting (#992 fallout).
    ///
    /// `CheckoutRevision.deadline` is 5 seconds, and that is the right number
    /// for the product: a person is waiting on a generation, and losing the
    /// revision record beats losing the run (L110).
    ///
    /// It is the wrong number for a test to inherit. `measure(inRepo:timeout:)`
    /// runs THREE git subprocesses, and since #992 the suite runs in parallel on
    /// as many workers as the machine has cores, so the machine a test is timing
    /// git against is loaded by the test runner itself. Measured on 2026-08-30
    /// at twelve workers: `CheckoutRevisionTests` failed on roughly one run in
    /// three, its reads taking 5.5s and 8.5s and coming back `.unknown`, which
    /// the tests correctly refused. Nothing was wrong with the code under test.
    /// The tests were asserting about how busy the machine was (L290, L522: a
    /// budget calibrated for one execution context is wrong when the same code
    /// is reached from another).
    ///
    /// Generous on purpose. Nothing here is measuring how FAST git is, so a
    /// large number costs nothing on a healthy run and only stops a loaded one
    /// reporting a defect that is not there. The deadline's own behaviour is
    /// still tested, deliberately and separately, by the test that passes
    /// `timeout: 0.5` against `/bin/sleep 30` and requires no answer back.
    static let deadlineForTests: TimeInterval = 120
}
#endif
