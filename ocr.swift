// Vox screen reader — OCRs a screenshot with Apple's Vision framework so the
// local LLM can draft replies from what's on screen. Nothing leaves the Mac.
// Usage: swift ocr.swift /tmp/vox-screen.png
import Vision
import AppKit

guard CommandLine.arguments.count > 1,
      let img = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: swift ocr.swift <image>\n".data(using: .utf8)!)
    exit(1)
}

let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true
try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
for obs in req.results ?? [] {
    if let s = obs.topCandidates(1).first?.string { print(s) }
}
