import XCTest
import AppKit

/// The program page scans are the only copies of the program (Salesforce sites
/// block re-download), and the baked PDF is what replaces them. Confirming the
/// OCR review deleted the scans unconditionally, so a bake that failed, or one
/// that was still running, took the program with it (#80).
///
/// Nothing may be destroyed before its replacement is verified to exist.
final class ProgramScanRetentionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProgramScanRetentionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func event(pages: [URL], pdf: URL?, fingerprint: String?) -> Event {
        var ev = Event(name: "Concert", org: "Org", venue: "Hall",
                       date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        ev.programImagePaths = pages
        ev.programPDFPath = pdf
        ev.programPDFFingerprint = fingerprint
        return ev
    }

    func testDeletesScansOnlyWhenTheBakedPDFIsOnDiskAndCurrent() throws {
        let pages = [try file("p1.png"), try file("p2.png")]
        let pdf = try file("program.pdf")
        let ev = event(pages: pages, pdf: pdf,
                       fingerprint: ProgramPDFBuilder.fingerprint(of: pages))

        XCTAssertEqual(ProgramScanRetention.decide(for: ev), .deleteScans)
    }

    func testKeepsScansWhenTheBakeNeverProducedAPath() throws {
        let pages = [try file("p1.png")]
        let ev = event(pages: pages, pdf: nil, fingerprint: nil)

        XCTAssertEqual(ProgramScanRetention.decide(for: ev),
                       .keepScans(reason: .pdfNotBuiltYet))
    }

    func testKeepsScansWhenTheRecordedPDFIsNotActuallyOnDisk() throws {
        let pages = [try file("p1.png")]
        let missing = dir.appendingPathComponent("program.pdf")   // never written
        let ev = event(pages: pages, pdf: missing,
                       fingerprint: ProgramPDFBuilder.fingerprint(of: pages))

        XCTAssertEqual(ProgramScanRetention.decide(for: ev),
                       .keepScans(reason: .pdfMissingOnDisk))
    }

    func testKeepsScansWhenThePDFWasBakedFromADifferentPageSet() throws {
        let pages = [try file("p1.png"), try file("p2.png")]
        let pdf = try file("program.pdf")
        let ev = event(pages: pages, pdf: pdf,
                       fingerprint: ProgramPDFBuilder.fingerprint(of: [pages[0]]))

        XCTAssertEqual(ProgramScanRetention.decide(for: ev),
                       .keepScans(reason: .pdfStale))
    }

    func testAnEventWithNoScansHasNothingToDelete() {
        let ev = event(pages: [], pdf: nil, fingerprint: nil)

        XCTAssertEqual(ProgramScanRetention.decide(for: ev), .nothingToDelete)
    }

    func testEveryKeepReasonSaysWhatToDoAboutIt() {
        for reason in ProgramScanRetention.KeepReason.allCases {
            XCTAssertFalse(reason.message.isEmpty, "\(reason) has nothing to show the user")
        }
    }
}
