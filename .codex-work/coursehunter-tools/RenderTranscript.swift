import Foundation

struct Lesson: Decodable {
    let title: String
    let duration: Int
}

struct Chunk: Decodable {
    let start: Double
    let end: Double
    let text: String
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
}

guard CommandLine.arguments.count == 6 else {
    fail("usage: RenderTranscript <course-id> <course-title> <lessons-json> <transcript-directory> <output-md>")
}

let courseID = CommandLine.arguments[1]
let courseTitle = CommandLine.arguments[2]
let lessonsURL = URL(fileURLWithPath: CommandLine.arguments[3])
let transcriptsURL = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[5])

guard let lessonsData = try? Data(contentsOf: lessonsURL),
      let lessons = try? JSONDecoder().decode([Lesson].self, from: lessonsData) else {
    fail("cannot decode lessons metadata")
}

var markdown = """
---
aliases:
  - CourseHunter \(courseID) — автоматическая транскрипция
tags:
  - тип/транскрипция
  - источник/coursehunter
  - язык/go
статус: черновик
---

# \(courseTitle) — транскрипция

> Автоматическая транскрипция создана локальной русской моделью macOS. Таймкоды относятся к отдельному видеоуроку, а не к суммарной длительности курса. Пунктуация и технические имена восстановлены не везде; точные формулировки задач, код и схемы проверяются по видео и кадрам в основном бланке.

"""

let decoder = JSONDecoder()
for (index, lesson) in lessons.enumerated() {
    let lessonNumber = index + 1
    let label = String(format: "%02d", lessonNumber)
    let transcriptURL = transcriptsURL.appendingPathComponent("lesson-\(label).jsonl")

    guard let raw = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
        fail("missing transcript for lesson \(lessonNumber)")
    }

    markdown += "## \(lesson.title)\n\n"
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
              let chunk = try? decoder.decode(Chunk.self, from: data) else {
            continue
        }
        markdown += "**\(timestamp(chunk.start))–\(timestamp(chunk.end))**  \n\(chunk.text)\n\n"
    }
}

do {
    try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("cannot write transcript: \(error.localizedDescription)")
}

print("lessons=\(lessons.count) bytes=\(markdown.utf8.count)")
