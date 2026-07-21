import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 3 else {
    fputs("usage: ocr_frames.swift INPUT_DIR OUTPUT_JSONL\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let files = try FileManager.default.contentsOfDirectory(
    at: inputURL,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
).filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

FileManager.default.createFile(atPath: outputURL.path, contents: nil)
let output = try FileHandle(forWritingTo: outputURL)
defer { try? output.close() }

for file in files {
    guard let nsImage = NSImage(contentsOf: file) else { continue }
    var rect = NSRect(origin: .zero, size: nsImage.size)
    guard let image = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["ru-RU", "en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

    let observations = (request.results ?? []).sorted {
        let dy = $0.boundingBox.midY - $1.boundingBox.midY
        return abs(dy) > 0.015 ? dy > 0 : $0.boundingBox.minX < $1.boundingBox.minX
    }
    let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    let data = try JSONSerialization.data(withJSONObject: ["file": file.lastPathComponent, "text": text])
    output.write(data)
    output.write(Data([0x0A]))
}

print("ocr_frames=\(files.count)")
