import AppKit
import AVFoundation
import Foundation

guard CommandLine.arguments.count >= 4 else {
    fputs("usage: extract_frames.swift VIDEO OUTPUT_DIR INTERVAL [START] [END]\n", stderr)
    exit(2)
}

let videoPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
guard let interval = Double(CommandLine.arguments[3]), interval > 0 else {
    fputs("invalid interval\n", stderr)
    exit(2)
}
let start = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 0 : 0

let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
let duration = try await asset.load(.duration).seconds
let requestedEnd = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5]) ?? duration : duration
let end = min(duration, requestedEnd)

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

var second = max(0, start)
var count = 0
while second < end {
    let time = CMTime(seconds: second, preferredTimescale: 600)
    let image = try generator.copyCGImage(at: time, actualTime: nil)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
        throw NSError(domain: "extract_frames", code: 1)
    }
    let millis = Int((second * 1000).rounded())
    let name = String(format: "frame-%09d.jpg", millis)
    try data.write(to: outputURL.appendingPathComponent(name), options: .atomic)
    count += 1
    second += interval
}

print("frames=\(count) duration=\(String(format: "%.3f", duration))")
