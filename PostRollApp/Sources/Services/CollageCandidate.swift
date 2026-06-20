import Foundation

/// One candidate collage layout for the layout-picker gallery: a rendered PNG
/// at `path` produced from `seed`. Storing the chosen `seed` as a day's collage
/// seed lets the final render reproduce the picked layout.
///
/// Standalone (not nested in PythonBridge) so the self-contained test bundle can
/// exercise CollageCandidateCache without importing the whole bridge.
struct CollageCandidate: Codable, Sendable, Hashable {
    let seed: Int
    let path: String
}
