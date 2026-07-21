import Foundation
import AppKit
import Speech

struct Word: Codable {
    let start: Double
    let end: Double
    let text: String
    let confidence: Float
}

struct Chunk: Codable {
    let start: Double
    let end: Double
    let text: String
    let words: [Word]
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func runTranscription() {

guard CommandLine.arguments.count == 5,
      let segmentSeconds = Double(CommandLine.arguments[4]),
      segmentSeconds > 0,
      segmentSeconds <= 59 else {
    fail("usage: TranscribeChunks <audio-directory> <output-jsonl> <locale> <segment-seconds <= 59>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let progressURL = URL(fileURLWithPath: CommandLine.arguments[2] + ".progress")
let traceURL = URL(fileURLWithPath: CommandLine.arguments[2] + ".trace")
let localeID = CommandLine.arguments[3]

func trace(_ message: String) {
    let line = Data((message + "\n").utf8)
    if !FileManager.default.fileExists(atPath: traceURL.path) {
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: traceURL) {
        try? handle.seekToEnd()
        handle.write(line)
        try? handle.close()
    }
}

trace("start locale=\(localeID)")

let files: [URL]
if inputURL.pathExtension.lowercased() == "txt" {
    guard let manifest = try? String(contentsOf: inputURL, encoding: .utf8) else {
        fail("cannot read chunk manifest: \(inputURL.path)")
    }
    files = manifest.split(separator: "\n", omittingEmptySubsequences: true).map {
        URL(fileURLWithPath: String($0))
    }
} else {
    guard let discovered = try? FileManager.default.contentsOfDirectory(
        at: inputURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        fail("cannot list chunk directory: \(inputURL.path)")
    }
    files = discovered.filter({ $0.pathExtension.lowercased() == "m4a" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
}

guard !files.isEmpty else {
    fail("no m4a chunks")
}

let authorization = DispatchSemaphore(value: 0)
var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
SFSpeechRecognizer.requestAuthorization { status in
    authorizationStatus = status
    authorization.signal()
}
authorization.wait()
trace("authorization=\(authorizationStatus.rawValue)")

guard authorizationStatus == .authorized else {
    fail("speech recognition is not authorized: \(authorizationStatus.rawValue)")
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
    fail("speech recognizer is unavailable for locale \(localeID)")
}
trace("recognizer on_device=\(recognizer.supportsOnDeviceRecognition)")

var startIndex = 0
if let rawProgress = try? String(contentsOf: progressURL, encoding: .utf8),
   let savedProgress = Int(rawProgress.trimmingCharacters(in: .whitespacesAndNewlines)),
   savedProgress >= 0,
   savedProgress <= files.count,
   FileManager.default.fileExists(atPath: outputURL.path) {
    startIndex = savedProgress
} else {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    try? "0\n".write(to: progressURL, atomically: true, encoding: .utf8)
}

guard let output = try? FileHandle(forWritingTo: outputURL) else {
    fail("cannot open output file: \(outputURL.path)")
}
defer { try? output.close() }
try? output.seekToEnd()

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

for index in startIndex..<files.count {
    let file = files[index]
    trace("chunk=\(index + 1)/\(files.count) file=\(file.lastPathComponent)")
    var result: SFSpeechRecognitionResult?
    var recognitionError: Error?
    var succeeded = false

    for attempt in 1...3 {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let completion = DispatchSemaphore(value: 0)
        var finished = false
        let task = recognizer.recognitionTask(with: request) { currentResult, error in
            if currentResult != nil || error != nil {
                trace("callback chunk=\(index + 1) final=\(currentResult?.isFinal == true) error=\(error?.localizedDescription ?? "none")")
            }
            if let currentResult {
                result = currentResult
            }
            if (currentResult?.isFinal == true || error != nil) && !finished {
                finished = true
                recognitionError = error
                completion.signal()
            }
        }
        completion.wait()
        task.finish()

        if result != nil {
            succeeded = true
            break
        }
        FileHandle.standardError.write(Data(("chunk=\(index + 1)/\(files.count) attempt=\(attempt) error=\(recognitionError?.localizedDescription ?? "no result")\n").utf8))
    }

    if !succeeded || result == nil {
        if recognitionError?.localizedDescription == "No speech detected" {
            trace("chunk=\(index + 1) no_speech=true")
            try? "\(index + 1)\n".write(to: progressURL, atomically: true, encoding: .utf8)
            continue
        }
        fail("recognition failed for \(file.lastPathComponent): \(recognitionError?.localizedDescription ?? "no result")")
    }

    guard let finalResult = result else {
        fail("recognition produced no result for \(file.lastPathComponent)")
    }

    let offset = Double(index) * segmentSeconds
    let words = finalResult.bestTranscription.segments.map { segment in
        Word(
            start: offset + segment.timestamp,
            end: offset + segment.timestamp + segment.duration,
            text: segment.substring,
            confidence: segment.confidence
        )
    }

    var grouped: [[Word]] = []
    var current: [Word] = []
    for word in words {
        if let first = current.first, let previous = current.last {
            let gap = word.start - previous.end
            let span = word.end - first.start
            if gap > 1.25 || span > 22.0 {
                grouped.append(current)
                current = []
            }
        }
        current.append(word)
    }
    if !current.isEmpty {
        grouped.append(current)
    }

    for group in grouped {
        guard let first = group.first, let last = group.last else { continue }
        let rawText = group.map(\.text).joined(separator: " ")
        let text = rawText
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " :", with: ":")
            .replacingOccurrences(of: " ;", with: ";")
        let chunk = Chunk(start: first.start, end: last.end, text: text, words: group)
        guard let encoded = try? encoder.encode(chunk) else {
            fail("cannot encode transcript chunk \(index + 1)")
        }
        output.write(encoded)
        output.write(Data([0x0a]))
    }
    try? output.synchronize()
    try? "\(index + 1)\n".write(to: progressURL, atomically: true, encoding: .utf8)

    if index % 10 == 0 || index + 1 == files.count {
        print("chunks=\(index + 1)/\(files.count)")
    }
}

print("complete chunks=\(files.count) locale=\(localeID) on_device=\(recognizer.supportsOnDeviceRecognition)")
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "CourseHunter — локальная расшифровка"
window.center()
window.makeKeyAndOrderFront(nil)
application.activate(ignoringOtherApps: true)
DispatchQueue.global(qos: .userInitiated).async {
    runTranscription()
    exit(0)
}
application.run()
