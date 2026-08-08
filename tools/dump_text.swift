// Dump what Apple Vision reads from a page, with each line's height in pixels.
//
// Used to pick the discriminating text for the tiling-threshold calibration
// (#207) and, separately, as the basis for the Vision cross-check in #209.
// Vision runs locally and free, so this costs nothing to re-run.
//
// Usage: swift tools/dump_text.swift <image>...

import Foundation
import Vision
import CoreGraphics
import ImageIO

for path in CommandLine.arguments.dropFirst() {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

    print("=== \((path as NSString).lastPathComponent) \(image.width)x\(image.height)")
    for obs in request.results ?? [] {
        guard let top = obs.topCandidates(1).first else { continue }
        let px = Double(obs.boundingBox.height) * Double(image.height)
        // x,y as fractions so a crop region can be derived without the image.
        print(String(format: "%6.1fpx  conf=%.2f  x=%.3f y=%.3f w=%.3f  %@",
                     px, top.confidence,
                     obs.boundingBox.minX, obs.boundingBox.minY,
                     obs.boundingBox.width, top.string))
    }
}
