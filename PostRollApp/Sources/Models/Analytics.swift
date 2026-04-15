import Foundation

// MARK: - Enums

enum IGMediaType: String, Codable, CaseIterable {
    case story, reel, image, carousel, video, unknown
}

enum OrgFollowerBand: String, Codable, CaseIterable, Identifiable {
    case under1k = "under1k"
    case k1to10  = "k1to10"
    case k10to50 = "k10to50"
    case k50plus = "k50plus"
    case unknown = "unknown"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .under1k: return "< 1k"
        case .k1to10:  return "1 to 10k"
        case .k10to50: return "10 to 50k"
        case .k50plus: return "50k+"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - IGPost

/// One Instagram post as imported from a Meta Business Suite CSV export.
/// Uses Meta's own stable `igPostID` as the Identifiable key — no synthetic UUID needed.
struct IGPost: Codable, Hashable {
    var igPostID: String
    var igPermalink: String
    var publishedAt: Date
    var mediaType: IGMediaType
    var rawPostType: String           // original Meta label for debugging
    var caption: String
    var hashtags: [String]            // parsed from caption by Python

    // Shared metrics
    var views: Int?
    var reach: Int?
    var likes: Int?
    var shares: Int?
    var follows: Int?

    // Feed-only (photos / carousels / reels)
    var comments: Int?
    var saves: Int?

    // Story-only
    var replies: Int?
    var navigation: Int?
    var profileVisits: Int?
    var stickerTaps: Int?

    var durationSec: Double?
    var org: String?                  // first @handle extracted from caption
    var isPersonal: Bool              // Claude flags non-concert posts during analysis

    enum CodingKeys: String, CodingKey {
        case igPostID       = "ig_post_id"
        case igPermalink    = "ig_permalink"
        case publishedAt    = "published_at"
        case mediaType      = "media_type"
        case rawPostType    = "raw_post_type"
        case caption
        case hashtags
        case views
        case reach
        case likes
        case shares
        case follows
        case comments
        case saves
        case replies
        case navigation
        case profileVisits  = "profile_visits"
        case stickerTaps    = "sticker_taps"
        case durationSec    = "duration_sec"
        case org
        case isPersonal     = "is_personal"
    }
}

extension IGPost: Identifiable {
    var id: String { igPostID }
}

// MARK: - Import result (returned by import_meta_csv.py)

struct MetaImportResult: Codable {
    var posts: [IGPost]
    var warnings: [String]
}

// MARK: - Insight Report

struct InsightReport: Identifiable, Codable, Hashable {
    var id: UUID
    var generatedAt: Date
    var dateRangeStart: Date
    var dateRangeEnd: Date
    var postCount: Int
    var storyCount: Int
    var feedCount: Int
    var summary: String
    var feedFindings: InsightFindings
    var storyFindings: InsightFindings
    var brandVoiceSuggestions: [String]
    var caveats: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case generatedAt            = "generated_at"
        case dateRangeStart         = "date_range_start"
        case dateRangeEnd           = "date_range_end"
        case postCount              = "post_count"
        case storyCount             = "story_count"
        case feedCount              = "feed_count"
        case summary
        case feedFindings           = "feed_findings"
        case storyFindings          = "story_findings"
        case brandVoiceSuggestions  = "brand_voice_suggestions"
        case caveats
    }
}

extension InsightReport {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                     = try c.decodeIfPresent(UUID.self,              forKey: .id)                     ?? UUID()
        generatedAt            = try c.decodeIfPresent(Date.self,              forKey: .generatedAt)            ?? Date()
        dateRangeStart         = try c.decodeIfPresent(Date.self,              forKey: .dateRangeStart)         ?? Date()
        dateRangeEnd           = try c.decodeIfPresent(Date.self,              forKey: .dateRangeEnd)           ?? Date()
        postCount              = try c.decodeIfPresent(Int.self,               forKey: .postCount)              ?? 0
        storyCount             = try c.decodeIfPresent(Int.self,               forKey: .storyCount)             ?? 0
        feedCount              = try c.decodeIfPresent(Int.self,               forKey: .feedCount)              ?? 0
        summary                = try c.decodeIfPresent(String.self,            forKey: .summary)                ?? ""
        feedFindings           = try c.decodeIfPresent(InsightFindings.self,   forKey: .feedFindings)           ?? InsightFindings(captionPatterns: [], hashtagPatterns: [], contentTypePatterns: [], timingPatterns: [])
        storyFindings          = try c.decodeIfPresent(InsightFindings.self,   forKey: .storyFindings)          ?? InsightFindings(captionPatterns: [], hashtagPatterns: [], contentTypePatterns: [], timingPatterns: [])
        brandVoiceSuggestions  = try c.decodeIfPresent([String].self,          forKey: .brandVoiceSuggestions)  ?? []
        caveats                = try c.decodeIfPresent([String].self,          forKey: .caveats)                ?? []
    }
}

struct InsightFindings: Codable, Hashable {
    var captionPatterns: [InsightFinding]
    var hashtagPatterns: [InsightFinding]
    var contentTypePatterns: [InsightFinding]
    var timingPatterns: [InsightFinding]

    enum CodingKeys: String, CodingKey {
        case captionPatterns      = "caption_patterns"
        case hashtagPatterns      = "hashtag_patterns"
        case contentTypePatterns  = "content_type_patterns"
        case timingPatterns       = "timing_patterns"
    }
}

extension InsightFindings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captionPatterns     = try c.decodeIfPresent([InsightFinding].self, forKey: .captionPatterns)     ?? []
        hashtagPatterns     = try c.decodeIfPresent([InsightFinding].self, forKey: .hashtagPatterns)     ?? []
        contentTypePatterns = try c.decodeIfPresent([InsightFinding].self, forKey: .contentTypePatterns) ?? []
        timingPatterns      = try c.decodeIfPresent([InsightFinding].self, forKey: .timingPatterns)      ?? []
    }
}

struct InsightFinding: Identifiable, Codable, Hashable {
    var id: UUID
    var headline: String
    var evidence: String
    var confidence: Confidence

    enum Confidence: String, Codable {
        case low, medium, high

        var color: String {
            switch self {
            case .low:    return "warmMid"
            case .medium: return "roseGold"
            case .high:   return "warmDark"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, headline, evidence, confidence
    }
}

extension InsightFinding {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(UUID.self,       forKey: .id)         ?? UUID()
        headline   = try c.decodeIfPresent(String.self,     forKey: .headline)   ?? ""
        evidence   = try c.decodeIfPresent(String.self,     forKey: .evidence)   ?? ""
        confidence = try c.decodeIfPresent(Confidence.self, forKey: .confidence) ?? .medium
    }
}
