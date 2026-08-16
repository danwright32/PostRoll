import Foundation
import Observation

@MainActor
@Observable
final class HashtagStore {
    var globalTags: [String] = []
    var presets: [HashtagPreset] = []

    struct HashtagPreset: Identifiable, Codable, Hashable {
        var id = UUID()
        var name: String = ""
        var tags: [String] = []
    }

    private static let globalKey  = "hashtagStore.globalTags"
    private static let presetsKey = "hashtagStore.presets"

    /// Reads the saved tags, which is what the app wants.
    ///
    /// `loadingSaved: false` is the seam the review sheet renders through
    /// (#645). Without it, drawing a caption card would read Dan's real
    /// UserDefaults, which is live data a test must be structurally unable to
    /// reach (L2), and would also make the picture depend on whatever tags
    /// happened to be saved that day.
    ///
    /// The same shape `AnalyticsStore(fileURL:)` already has, for the same
    /// reason.
    init(loadingSaved: Bool = true) {
        if loadingSaved { load() }
    }

    func save() {
        UserDefaults.standard.set(globalTags, forKey: Self.globalKey)
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    private func load() {
        globalTags = UserDefaults.standard.stringArray(forKey: Self.globalKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.presetsKey),
           let loaded = try? JSONDecoder().decode([HashtagPreset].self, from: data) {
            presets = loaded
        }
    }

    func addPreset(name: String, tags: [String]) {
        presets.append(HashtagPreset(name: name, tags: tags))
        save()
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }
}
