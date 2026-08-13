import XCTest

/// #495: the restore doc's inventory named a folder nothing creates and left
/// out three that exist, in exactly the document somebody follows while they
/// are losing data.
///
/// Both directions, because either one alone passes while the doc is wrong
/// (L96): a doc row with no code behind it sends Dan looking for a folder that
/// is not there, and a real file with no doc row is one he does not know to
/// keep.
final class DataInventoryDocTests: XCTestCase {

    private func docRows() throws -> [String] {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/BACKUP-AND-RESTORE.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("| `") }
    }

    func testTheDocTableIsExactlyTheInventory() throws {
        XCTAssertEqual(try docRows(), DataInventory.markdownRows)
    }

    func testEveryFolderTheAppWritesIsAccountedFor() throws {
        // The names the app itself creates, read off the same layout the app
        // uses, so renaming one and forgetting the doc is a failing test rather
        // than a wrong instruction discovered during a restore.
        let layout = AppPaths.Layout(root: URL(fileURLWithPath: "/tmp/inventory-check"))
        let expected = [
            layout.eventsFile, layout.analyticsFile, layout.accountsFile,
            layout.brandVoiceFile, layout.photosDir, layout.audioDir,
            layout.clipsDir, layout.programsDir, layout.previewDir,
            layout.logsDir, layout.progressDir,
        ].map(\.lastPathComponent)

        let listed = Set(DataInventory.items.map {
            $0.name.hasSuffix("/") ? String($0.name.dropLast()) : $0.name
        })
        for name in expected {
            XCTAssertTrue(listed.contains(name), "\(name) is on disk and not in the inventory")
        }
    }

    func testTheInventoryNamesNothingTheAppNeverCreates() throws {
        // The row that started this: an `output/` folder that has never
        // existed. Exports go to a folder the person picks, outside the data
        // root entirely.
        let names = DataInventory.items.map(\.name)
        XCTAssertFalse(names.contains { $0.hasPrefix("output") },
                       "the inventory promises an output folder: \(names)")
    }
}
