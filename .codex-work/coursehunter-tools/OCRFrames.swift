import AppKit
import Foundation
import Vision

struct FrameOCR: Codable {
    let file: String
    let text: String
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: OCRFrames <image-directory> <output-jsonl>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let files = try? FileManager.default.contentsOfDirectory(
    at: inputURL,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
).filter({ ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
    fail("cannot list input directory: \(inputURL.path)")
}

FileManager.default.createFile(atPath: outputURL.path, contents: nil)
guard let output = try? FileHandle(forWritingTo: outputURL) else {
    fail("cannot open output file: \(outputURL.path)")
}
defer { try? output.close() }

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

var processed = 0
for file in files {
    guard let image = NSImage(contentsOf: file),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write(Data(("cannot decode: \(file.path)\n").utf8))
        continue
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["ru-RU", "en-US"]

    do {
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted { left, right in
            let verticalDelta = left.boundingBox.midY - right.boundingBox.midY
            if abs(verticalDelta) > 0.02 { return verticalDelta > 0 }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let record = FrameOCR(file: file.lastPathComponent, text: text)
        output.write(try encoder.encode(record))
        output.write(Data([0x0a]))
        processed += 1
    } catch {
        FileHandle.standardError.write(Data(("OCR failed for \(file.path): \(error.localizedDescription)\n").utf8))
    }
}

print("frames=\(processed)")
