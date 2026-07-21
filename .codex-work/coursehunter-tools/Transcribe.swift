import Foundation
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

guard CommandLine.arguments.count >= 3 else {
    fail("usage: Transcribe <media-file> <output-jsonl> [locale]")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let localeID = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "ru-RU"

guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("input file does not exist: \(inputURL.path)")
}

let authorization = DispatchSemaphore(value: 0)
var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
SFSpeechRecognizer.requestAuthorization { status in
    authorizationStatus = status
    authorization.signal()
}
authorization.wait()

guard authorizationStatus == .authorized else {
    fail("speech recognition is not authorized: \(authorizationStatus.rawValue)")
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
    fail("speech recognizer is unavailable for locale \(localeID)")
}

let request = SFSpeechURLRecognitionRequest(url: inputURL)
request.shouldReportPartialResults = false
request.taskHint = .dictation
if recognizer.supportsOnDeviceRecognition {
    request.requiresOnDeviceRecognition = true
}
if #available(macOS 13.0, *) {
    request.addsPunctuation = true
}

let completion = DispatchSemaphore(value: 0)
var finalResult: SFSpeechRecognitionResult?
var finalError: Error?
var completed = false

let task = recognizer.recognitionTask(with: request) { result, error in
    if let result {
        finalResult = result
        let count = result.bestTranscription.segments.count
        FileHandle.standardError.write(Data(("segments=\(count) final=\(result.isFinal)\n").utf8))
    }

    if (result?.isFinal == true || error != nil) && !completed {
        completed = true
        finalError = error
        completion.signal()
    }
}

completion.wait()
task.finish()

if let finalError, finalResult == nil {
    fail("recognition failed: \(finalError.localizedDescription)")
}

guard let result = finalResult else {
    fail("recognition produced no result")
}

let words = result.bestTranscription.segments.map { segment in
    Word(
        start: segment.timestamp,
        end: segment.timestamp + segment.duration,
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

let chunks = grouped.compactMap { group -> Chunk? in
    guard let first = group.first, let last = group.last else { return nil }
    let rawText = group.map(\.text).joined(separator: " ")
    let text = rawText
        .replacingOccurrences(of: " ,", with: ",")
        .replacingOccurrences(of: " .", with: ".")
        .replacingOccurrences(of: " !", with: "!")
        .replacingOccurrences(of: " ?", with: "?")
        .replacingOccurrences(of: " :", with: ":")
        .replacingOccurrences(of: " ;", with: ";")
    return Chunk(start: first.start, end: last.end, text: text, words: group)
}

FileManager.default.createFile(atPath: outputURL.path, contents: nil)
guard let handle = try? FileHandle(forWritingTo: outputURL) else {
    fail("cannot open output file: \(outputURL.path)")
}
defer { try? handle.close() }

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
for chunk in chunks {
    let line = try encoder.encode(chunk)
    handle.write(line)
    handle.write(Data([0x0a]))
}

print("chunks=\(chunks.count) words=\(words.count) locale=\(localeID) on_device=\(recognizer.supportsOnDeviceRecognition)")
