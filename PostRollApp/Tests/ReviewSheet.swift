#if POSTROLL_TESTS
import AppKit
import Foundation

/// The one folder every measured screen is written into, so a visual change can
/// be reviewed at a glance instead of by launching the app and navigating to
/// each screen in turn (#623).
///
/// Why this exists at all: #611 changed the colour of type in fourteen places
/// across three screens, and the only review available was by hand, in the
/// running app. Every one of those screens was already being rendered by the
/// suite, several times over, and the pictures were thrown away.
///
/// ## Why the folder is decided here rather than passed in
///
/// The two dump tests that came before this took their destination from an
/// environment variable, and that never worked from a command line: xcodebuild
/// does not forward the ambient environment to the test process, and the
/// `TEST_RUNNER_` prefix that does forward is a UI-test mechanism. Both were
/// measured against a real run before this was written. Each dump then fell
/// back to a temporary directory, wrote its files there, counted them there,
/// and passed, so the caller's folder stayed empty while the run reported
/// success (L100).
///
/// So the location is decided in ONE place, here, and the make target learns it
/// from what the run PRINTS rather than by spelling it a second time (L41).
/// A path both sides declare separately is a path they can disagree about.
enum ReviewSheet {

    /// What a run prints so its caller can find the folder without knowing it.
    static let folderMarker = "REVIEW-SHEET-FOLDER "
    /// And what it wrote there, per group, so a caller can tell a full sheet
    /// from a partial one.
    static let countMarker = "REVIEW-SHEET-WROTE "
    /// Where the run BEFORE this one was kept, so a caller can say what moved.
    static let baselineMarker = "REVIEW-SHEET-BASELINE "

    /// Where both folders live.
    ///
    /// Under Caches rather than in the checkout: the repository lives in
    /// ~/Documents, which iCloud syncs, so images written there are uploaded,
    /// counted against Dan's storage and conflict-copied. Not under the build
    /// cache either, so `make clean` does not take the sheet with it.
    private static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/PostRoll")

    /// The previous run, kept so a change can report itself (#636).
    ///
    /// The whole of #619 and #620 was reviewed by copying this folder aside by
    /// hand before re-rendering, twice, because "19 of 82 screens moved" was
    /// the answer that made the change reviewable at all: it said the change
    /// was confined, and where to look. Doing that by hand means it only
    /// happens when somebody remembers to.
    ///
    /// Deliberately the LAST RUN rather than a committed golden. A recorded
    /// expectation defends whatever it captured, including a state nobody
    /// checked (L84), so this says only that a screen CHANGED. Whether a screen
    /// is correct stays the business of the ink and footprint checks.
    ///
    /// Declared from `root` rather than from `folder`, because a static let
    /// that read `folder` while `folder` was being initialised would deadlock
    /// on its own once-token.
    /// Created alongside `folder`, so `begin(group:)` can always list it.
    static let previous = root.appendingPathComponent("review-sheet-previous")

    /// The folder itself. Created if it is not there, and never emptied here.
    ///
    /// It used to be emptied from this initialiser, with the reason written
    /// beside it: "once per process rather than once per dump test, because
    /// three test classes write into this one folder and a clear inside each
    /// would delete the others' work. `static let` is Swift's once, which is
    /// what makes that safe without any ordering between the classes."
    ///
    /// That is true while there is exactly one test process, and #992 removes
    /// that. XCTest's parallel mode runs test classes in separate processes, so
    /// every worker runs this initialiser and clears the one shared folder.
    /// Measured on 2026-08-30, the first parallel run of this suite:
    /// `testDumpEveryMeasuredScreenForReview` rendered 82 screens and found
    /// fewer on disk, because a sibling worker had emptied the folder
    /// underneath it. The comment above was the only record of the invariant,
    /// and the code it justified became destructive the moment it went (L204).
    ///
    /// So the clearing moved to `begin(group:)`, which each dump test calls for
    /// its OWN group. A group is written by exactly one test in exactly one
    /// class, so two workers never touch the same files and the answer no
    /// longer depends on how many processes there are.
    ///
    /// The markers still print once per process, which is once per worker now.
    /// The `review-sheet` make target already takes `head -1` of each, so
    /// several identical lines say the same thing they always did.
    static let folder: URL = {
        let url = root.appendingPathComponent("review-sheet")
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        try? manager.createDirectory(at: previous, withIntermediateDirectories: true)
        print("\(folderMarker)\(url.path)")
        print("\(baselineMarker)\(previous.path)")
        return url
    }()

    /// Clears one group out of the sheet, keeping it as that group's baseline.
    ///
    /// Called by each dump test before it writes. Scoped to the group for the
    /// reason above, and MOVING rather than deleting for the reason it always
    /// did: the run being replaced is what `make review-sheet` compares against,
    /// and "19 of 82 screens moved" is the answer that makes a change reviewable
    /// (#636).
    ///
    /// The layout stays flat. The make target reads the folder with
    /// `ls | grep '\.png$'` and iterates `"$folder"/*.png`, so putting each
    /// group in its own subdirectory would have broken the sheet itself.
    ///
    /// Throwing rather than `try?`. A rotation that silently did nothing leaves
    /// last run's images in place and the dump then counts them as its own, so
    /// a sheet of stale pictures would report as a full one (L98).
    static func begin(group: String) throws {
        let manager = FileManager.default
        _ = folder                                  // creates both directories
        let prefix = "\(fileSafe(group))--"

        for name in try manager.contentsOfDirectory(atPath: previous.path)
        where name.hasPrefix(prefix) && name.hasSuffix(".png") {
            try manager.removeItem(at: previous.appendingPathComponent(name))
        }

        for name in try manager.contentsOfDirectory(atPath: folder.path)
        where name.hasPrefix(prefix) && name.hasSuffix(".png") {
            try manager.moveItem(at: folder.appendingPathComponent(name),
                                 to: previous.appendingPathComponent(name))
        }
    }

    /// Writes one surface under a name a person can read off a file listing.
    ///
    /// The group leads the name so the sheet sorts into the screens it came
    /// from rather than into an alphabet of unrelated states.
    @discardableResult
    static func write(_ rep: NSBitmapImageRep,
                      group: String,
                      name: String) throws -> URL {
        let file = folder.appendingPathComponent(
            "\(fileSafe(group))--\(fileSafe(name)).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SheetError.couldNotEncode(file.lastPathComponent)
        }
        try png.write(to: file)
        return file
    }

    /// How many images of a group are on disk, which is the only honest way to
    /// answer whether a dump did what it said: counting what it MEANT to write
    /// is counting the loop it just ran.
    static func written(group: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("\(fileSafe(group))--") && $0.hasSuffix(".png") }
            .sorted()
    }

    /// Says what reached disk, in the shape the make target reads.
    static func announce(group: String, count: Int) {
        print("\(countMarker)\(count) \(group)")
    }

    private static func fileSafe(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
    }

    enum SheetError: Error, CustomStringConvertible {
        case couldNotEncode(String)

        var description: String {
            switch self {
            case .couldNotEncode(let name):
                return "\(name) could not be encoded as PNG, so the sheet is "
                    + "missing a surface it reports as covered"
            }
        }
    }
}
#endif
