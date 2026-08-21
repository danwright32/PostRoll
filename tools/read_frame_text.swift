// Read the words out of a rendered frame, so a check can ask whether they are
// the RIGHT words (#754).
//
// Everything else in this repo measures a frame's APPEARANCE: whether ink is
// present in a declared band, and how far it is from what sits behind it. None
// of that can tell a story rendered for "The One-Man Odyssey" from one that
// rendered a blank title, the previous day's title, or a truncated one. Each of
// those passes every check we have and reports a clean run.
//
// Apple's Vision is used because it is on the machine already: it costs
// nothing, needs no Python dependency and no network, and it reads SignPainter,
// the script face the titles are set in, at confidence 1.00 (measured
// 2026-08-20 across the story, collage, before/after and scroll reel headers).
// The alternative in the repo, postroll/ai/ocr_program.py, goes to the metered
// Claude API, which a test may not touch.
//
// Run as `swift tools/read_frame_text.swift <image> [left top right bottom]`.
// One line per reading: confidence, a tab, then the text.
//
// Exit codes are distinct, because "could not read the file", "Vision refused"
// and "read it and there were no words" are three different answers and only
// the last of them is a measurement:
//
//     0  read the image; every reading is on stdout, and there may be none
//     2  the image could not be opened or decoded
//     3  Vision itself failed
//     4  the arguments were not usable

import Foundation
import Vision
import AppKit

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write("read_frame_text: \(message)\n".data(using: .utf8)!)
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 || arguments.count == 5 else {
    fail(4, "usage: read_frame_text.swift <image> [left top right bottom]")
}

let path = arguments[0]
guard let image = NSImage(contentsOfFile: path),
      let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail(2, "could not open or decode \(path)")
}

// Cropped here rather than by the caller writing a second file, so the only
// thing on disk is the frame as it was rendered.
var cgImage = full
if arguments.count == 5 {
    let numbers = arguments.dropFirst().map { Int($0) }
    guard numbers.allSatisfy({ $0 != nil }) else {
        fail(4, "the box must be four integers: left top right bottom")
    }
    let (left, top, right, bottom) = (numbers[0]!, numbers[1]!, numbers[2]!, numbers[3]!)
    guard right > left, bottom > top,
          left >= 0, top >= 0, right <= full.width, bottom <= full.height else {
        fail(4, "the box (\(left), \(top), \(right), \(bottom)) is not inside "
             + "the \(full.width)x\(full.height) frame")
    }
    guard let cropped = full.cropping(to: CGRect(x: left, y: top,
                                                 width: right - left,
                                                 height: bottom - top)) else {
        fail(2, "could not crop \(path) to (\(left), \(top), \(right), \(bottom))")
    }
    cgImage = cropped
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// Off deliberately. Language correction rewrites what it saw into what it
// expects, which is precisely the difference this exists to measure: a
// truncated title corrected back into a whole word would report the frame as
// naming a show it does not name.
request.usesLanguageCorrection = false

do {
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
} catch {
    fail(3, "Vision could not read \(path): \(error.localizedDescription)")
}

for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    print("\(String(format: "%.4f", candidate.confidence))\t\(candidate.string)")
}
