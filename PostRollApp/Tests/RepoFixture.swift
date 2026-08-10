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
}
