import AVFoundation
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count == 4,
      let segmentSeconds = Double(CommandLine.arguments[3]),
      segmentSeconds > 0,
      segmentSeconds <= 600 else {
    fail("usage: SplitAudio <media-file> <output-directory> <segment-seconds <= 600>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("input file does not exist: \(inputURL.path)")
}

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let asset = AVURLAsset(url: inputURL)
let duration = CMTimeGetSeconds(asset.duration)
guard duration.isFinite, duration > 0 else {
    fail("cannot read media duration")
}

let segmentCount = Int(ceil(duration / segmentSeconds))
for index in 0..<segmentCount {
    let start = Double(index) * segmentSeconds
    let length = min(segmentSeconds, duration - start)
    let name = String(format: "chunk-%05d.m4a", index)
    let destination = outputURL.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
        continue
    }

    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        fail("cannot create exporter for chunk \(index)")
    }

    exporter.outputURL = destination
    exporter.outputFileType = .m4a
    exporter.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: length, preferredTimescale: 600)
    )

    let completion = DispatchSemaphore(value: 0)
    exporter.exportAsynchronously {
        completion.signal()
    }
    completion.wait()

    guard exporter.status == .completed else {
        try? FileManager.default.removeItem(at: destination)
        fail("chunk \(index) export failed: \(exporter.error?.localizedDescription ?? "unknown error")")
    }

    if index % 20 == 0 || index + 1 == segmentCount {
        print("chunks=\(index + 1)/\(segmentCount)")
    }
}

print("complete chunks=\(segmentCount) duration=\(duration)")
