import Foundation
import Observation

@MainActor
@Observable
final class AnalyticsStore {
    var posts: [IGPost] = []
    var reports: [InsightReport] = []
    var orgFollowerBands: [String: OrgFollowerBand] = [:]
    var lastImport: Date?

    private static let filePath: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/PostRoll/analytics.json")

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

    init() { load() }

    // MARK: - Persistence

    func save() {
        let stored = StoredData(
            posts: posts,
            reports: reports,
            orgFollowerBands: orgFollowerBands,
            lastImport: lastImport
        )
        do {
            let data = try Self.encoder.encode(stored)
            try data.write(to: Self.filePath, options: .atomic)
        } catch {
            NSLog("AnalyticsStore: failed to save analytics.json: \(error)")
        }
    }

    private func load() {
        let url = Self.filePath
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let stored = try Self.decoder.decode(StoredData.self, from: data)
            posts = stored.posts
            reports = stored.reports
            orgFollowerBands = stored.orgFollowerBands
            lastImport = stored.lastImport
        } catch {
            // Do not leave an undecodable file in place: the next save would
            // overwrite it and discard all imported history. Set it aside.
            NSLog("AnalyticsStore: failed to decode analytics.json: \(error)")
            StoreRecovery.setAside(url)
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
