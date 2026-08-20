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

    /// Whether to read the saved tags, said out loud by every caller.
    ///
    /// `loadingSaved: false` is the seam the review sheet renders through
    /// (#645). Without it, drawing a caption card would read Dan's real
    /// UserDefaults, which is live data a test must be structurally unable to
    /// reach (L2), and would also make the picture depend on whatever tags
    /// happened to be saved that day.
    ///
    /// It used to default to true, and two tests took the default: the screen
    /// rendering sweep and the owners list both built one that read his saved
    /// tags (#722). The same shape `AnalyticsStore(fileURL:)` has, for the same
    /// reason.
    init(loadingSaved: Bool) {
        if loadingSaved { load() }
    }

    #if !POSTROLL_TESTS
    /// The app's own store, reading what Dan has saved.
    ///
    /// Compiled out of the test bundle, so a test that does not say which it
    /// wants is a build error rather than a silent read of live data.
    convenience init() {
        self.init(loadingSaved: true)
    }
    #endif

    func save() {
        AppPreferences.store.set(globalTags, forKey: Self.globalKey)
        if let data = try? JSONEncoder().encode(presets) {
            AppPreferences.store.set(data, forKey: Self.presetsKey)
        }
    }

    private func load() {
        globalTags = AppPreferences.store.stringArray(forKey: Self.globalKey) ?? []
        if let data = AppPreferences.store.data(forKey: Self.presetsKey),
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
