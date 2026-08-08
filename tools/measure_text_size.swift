// Measure how big the printed text actually is on a program page (#207).
//
// The tiling fix for #200 needs a rule for how far a page may be reduced before
// the model starts misreading letters ("Safa" -> "5afa"). Two API data points
// exist: 0.25 of native FAILS, 0.45 PASSES, on one program. A scale factor is
// the wrong thing to hardcode, because it only means anything relative to how
// big the type was to begin with, and that differs per program.
//
// What transfers between programs is the RENDERED SIZE of a line of text, in
// pixels, in the image the model finally sees. This measures that locally with
// Vision, so the threshold can be calibrated once and then applied to any page
// without paying for an API call per page.
//
// Usage:  swift tools/measure_text_size.swift <image-or-pdf-page>...
// Output: one TSV row per page, plus a summary.

import Foundation
import Vision
import CoreGraphics
import ImageIO

struct PageMeasurement {
    let path: String
    let width: Int
    let height: Int
    let medianLineHeightPx: Double
    let p10LineHeightPx: Double
    let lines: Int
}

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func measure(_ path: String) -> PageMeasurement? {
    guard let image = loadImage(path) else {
        FileHandle.standardError.write("could not read \(path)\n".data(using: .utf8)!)
        return nil
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        FileHandle.standardError.write("vision failed on \(path): \(error)\n".data(using: .utf8)!)
        return nil
    }

    guard let observations = request.results, !observations.isEmpty else { return nil }

    // Vision's boundingBox is normalised; height * image height is the line's
    // height in native pixels. Small print (performer lists, credits) is what
    // actually breaks, so the 10th percentile matters more than the median.
    let heights = observations
        .map { Double($0.boundingBox.height) * Double(image.height) }
        .sorted()

    func percentile(_ p: Double) -> Double {
        let idx = max(0, min(heights.count - 1, Int(Double(heights.count - 1) * p)))
        return heights[idx]
    }

    return PageMeasurement(
        path: (path as NSString).lastPathComponent,
        width: image.width,
        height: image.height,
        medianLineHeightPx: percentile(0.5),
        p10LineHeightPx: percentile(0.10),
        lines: heights.count
    )
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    print("usage: swift tools/measure_text_size.swift <image>...")
    exit(2)
}

print("page\twidth\theight\tlines\tmedian_line_px\tp10_line_px\tp10_at_1568_long_edge")
var measured: [PageMeasurement] = []
for path in paths {
    guard let m = measure(path) else { continue }
    measured.append(m)
    // What that smallest text becomes once the current shipped path shrinks
    // the page to a 1568px long edge, which is where #200 was found.
    let scaleTo1568 = 1568.0 / Double(max(m.width, m.height))
    let shrunk = m.p10LineHeightPx * min(1.0, scaleTo1568)
    print(String(format: "%@\t%d\t%d\t%d\t%.1f\t%.1f\t%.1f",
                 m.path, m.width, m.height, m.lines,
                 m.medianLineHeightPx, m.p10LineHeightPx, shrunk))
}

if measured.isEmpty { exit(1) }
