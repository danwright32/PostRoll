import Foundation

/// Which points across a clip's trim window the per-clip crop editor (#151)
/// pulls preview frames from: start, middle, end, mirroring
/// select_reel_clips.py's Stage 2 frame-extraction spread so a crop that
/// drifts off-subject partway through a shot is visible before it ships.
enum ClipCropFrameStrip {
    static func sampleTimes(trimIn: Double, trimOut: Double) -> [Double] {
        guard trimOut > trimIn else { return [trimIn] }
        return [trimIn, (trimIn + trimOut) / 2, trimOut]
    }
}
