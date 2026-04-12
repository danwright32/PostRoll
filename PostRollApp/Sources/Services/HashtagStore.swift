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

    init() { load() }

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
