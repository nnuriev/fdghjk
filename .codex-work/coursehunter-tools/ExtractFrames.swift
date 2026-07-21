import AppKit
import AVFoundation
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count >= 4 else {
    fail("usage: ExtractFrames <media-file> <output-directory> <second> [second ...]")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let seconds = CommandLine.arguments.dropFirst(3).compactMap(Double.init)

guard !seconds.isEmpty else { fail("no valid timestamps supplied") }
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let asset = AVURLAsset(url: inputURL)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = NSSize(width: 1920, height: 1080)
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

var created = 0
for second in seconds {
    let requested = CMTime(seconds: second, preferredTimescale: 600)
    do {
        let image = try generator.copyCGImage(at: requested, actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            fail("cannot encode frame at \(second)")
        }
        let milliseconds = Int((second * 1000).rounded())
        let name = String(format: "frame-%09d.jpg", milliseconds)
        try data.write(to: outputURL.appendingPathComponent(name), options: .atomic)
        created += 1
    } catch {
        FileHandle.standardError.write(Data(("frame \(second) failed: \(error.localizedDescription)\n").utf8))
    }
}

print("frames=\(created)")
