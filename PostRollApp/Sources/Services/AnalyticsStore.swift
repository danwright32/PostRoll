import Foundation
import Observation

@MainActor
@Observable
final class AnalyticsStore {
    var posts: [IGPost] = []
    var reports: [InsightReport] = []
    var orgFollowerBands: [String: OrgFollowerBand] = [:]
    var lastImport: Date?

    /// Injectable so tests are structurally unable to touch the real
    /// analytics.json. A test that can reach live data will eventually
    /// destroy some.
    private let fileURL: URL

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = AnalyticsDates.lenientDecoding
        return d
    }()

    /// Set when analytics.json could not be read, so the Insights screen can
    /// say the history could not be loaded instead of rendering an empty state
    /// over a failure (#88). An empty state and an error state are different
    /// screens.
    var recoveryMessage: String?

    init(fileURL: URL = AppPaths.analyticsFile) {
        self.fileURL = fileURL
        load()
    }

    /// nonisolated: pure text, and the tests that pin its wording have no
    /// reason to hop to the main actor to read a string.
    nonisolated static func recoveryText(setAsideAs name: String?, restorable: Bool) -> String {
        var text = "Your imported Instagram history could not be read, so Insights is starting empty. "
        if let name {
            text += "Nothing was deleted: the unreadable file was set aside as \(name). "
        } else {
            text += "The unreadable file could not be set aside, so it is still in place. "
        }
        text += restorable
            ? "A recent good backup exists and can be restored."
            : "There is no earlier backup to restore from yet."
        return text
    }

    // MARK: - Persistence

    @discardableResult
    func save() -> StoreSaveOutcome {
        // The gate events.json has had since #88 (#439). Without it, a file this
        // store failed to READ was written over by the next import, and what it
        // wrote was the empty list the failed read had produced.
        guard !StoreSaveGate.shared.isBlocked(fileURL) else {
            NSLog("AnalyticsStore: refusing to save; analytics.json could not be read and must not be overwritten")
            return .blocked
        }

        let stored = StoredData(
            posts: posts,
            reports: reports,
            orgFollowerBands: orgFollowerBands,
            lastImport: lastImport
        )
        do {
            let data = try Self.encoder.encode(stored)
            // Same protection events.json gets (#88): analytics.json holds
            // every imported Instagram post and report, and reconstructing it
            // means re-exporting from Meta. It had no backup at all.
            StoreBackups.rotate(store: fileURL) { candidate in
                (try? Self.decoder.decode(StoredData.self, from: candidate)) != nil
            }
            try data.write(to: fileURL, options: .atomic)
            return .saved
        } catch {
            NSLog("AnalyticsStore: failed to save analytics.json: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    private func load() {
        let url = fileURL

        // No `fileExists` check here on purpose. It returns false for a path the
        // process is DENIED as well as for one that is absent, so a TCC refusal
        // used to read as a first launch: Insights showed an empty history, and
        // the next save wrote that emptiness over every imported post. Only the
        // error from the read itself tells the two apart (#439).
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.isFileNotFound {
            StoreSaveGate.shared.unblock(url)
            return
        } catch {
            // Unknown contents, not invalid contents. The file stays exactly
            // where it is, unrenamed, and nothing is written over it.
            NSLog("AnalyticsStore: could not read analytics.json: \(error)")
            StoreSaveGate.shared.block(url)
            recoveryMessage = StoreRecoveryText.unreadable(
                "Your imported Instagram history", error)
            return
        }

        do {
            let stored = try Self.decoder.decode(StoredData.self, from: data)
            posts = stored.posts
            reports = stored.reports
            orgFollowerBands = stored.orgFollowerBands
            lastImport = stored.lastImport
            StoreSaveGate.shared.unblock(url)
        } catch let error as DecodingError {
            // Genuine corruption: the bytes are there and they are not analytics
            // data. Do not leave it in place, because the next save would
            // overwrite it and discard all imported history. Set it aside.
            NSLog("AnalyticsStore: failed to decode analytics.json: \(error)")
            let setAside = StoreRecovery.setAside(url)
            if setAside == nil {
                // The original could not be preserved, so it is still the only
                // copy. Saving now would erode it one generation at a time.
                StoreSaveGate.shared.block(url)
            } else {
                StoreSaveGate.shared.unblock(url)
            }
            // Say so. This used to be an NSLog and nothing else, so the entire
            // imported history could vanish and the only evidence was the
            // Insights screen looking empty, which reads as "no data imported
            // yet" rather than "your data could not be read" (#88).
            recoveryMessage = Self.recoveryText(setAsideAs: setAside?.lastPathComponent,
                                                restorable: StoreBackups.newest(for: url) != nil)
        } catch {
            // Not a decode failure, so there is no evidence the file is bad.
            // Never rename on an error we do not understand.
            NSLog("AnalyticsStore: unexpected failure reading analytics.json: \(error)")
            StoreSaveGate.shared.block(url)
            recoveryMessage = StoreRecoveryText.unreadable(
                "Your imported Instagram history", error)
        }
    }

    // MARK: - Posts

    /// Merge a new batch of posts, deduping on igPostID. Newer import wins.
    func mergePosts(_ new: [IGPost]) {
        var byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.igPostID, $0) })
        for post in new { byID[post.igPostID] = post }
        posts = byID.values.sorted { $0.publishedAt > $1.publishedAt }
        lastImport = Date()
        save()
    }

    // MARK: - Reports

    func addReport(_ report: InsightReport) {
        reports.insert(report, at: 0)
        save()
    }

    // MARK: - Org bands

    func setOrgBand(_ org: String, _ band: OrgFollowerBand) {
        orgFollowerBands[org] = band
        save()
    }

    // MARK: - Derived

    /// Unique orgs from post captions (first @-mention), sorted alphabetically.
    var uniqueOrgs: [String] {
        Array(Set(posts.compactMap(\.org))).sorted()
    }

    var feedPosts: [IGPost] { posts.filter { $0.mediaType != .story } }
    var storyPosts: [IGPost] { posts.filter { $0.mediaType == .story } }

    // MARK: - Private envelope

    private struct StoredData: Codable {
        var posts: [IGPost]
        var reports: [InsightReport]
        var orgFollowerBands: [String: OrgFollowerBand]
        var lastImport: Date?
    }
}
