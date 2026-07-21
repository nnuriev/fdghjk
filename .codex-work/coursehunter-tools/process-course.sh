#!/bin/zsh

set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "usage: process-course.sh <course-id> <start-lesson-number> [max-parallel-transcriptions]"
  exit 2
fi

course_id="$1"
start_lesson="$2"
max_parallel="${3:-3}"
workspace="/Users/nnuriev/Documents/interview"
api_example="/Users/nnuriev/.codex/attachments/b0d356f7-8ba0-4dfa-beb4-613dad7ee2ee/pasted-text-1.txt"
tools_dir="$workspace/.codex-work/coursehunter-tools"
course_dir="$workspace/.codex-work/coursehunter-$course_id"
videos_dir="$course_dir/videos"
transcripts_dir="$course_dir/transcripts"
frames_dir="$course_dir/coarse-frames"
logs_dir="$course_dir/logs"
metadata="$course_dir/lessons.json"
transcriber_app="$tools_dir/CourseHunterTranscriber.app"

mkdir -p "$videos_dir" "$transcripts_dir" "$frames_dir" "$logs_dir"

course_cookie=$(awk -F"'" '/^  -b / {print $2; exit}' "$api_example")
if [[ -z "$course_cookie" ]]; then
  print -u2 "cannot read CourseHunter cookie"
  exit 1
fi

/usr/bin/curl -fsS -b "$course_cookie" -A 'Mozilla/5.0' \
  "https://coursehunter.net/api/v1/course/$course_id/lessons" -o "$metadata"

lesson_count=$(/usr/bin/jq 'length' "$metadata")
if (( lesson_count == 0 )); then
  print -u2 "course $course_id has no lessons"
  exit 1
fi

active_transcriptions() {
  (/usr/bin/pgrep -f "$transcriber_app/Contents/MacOS/transcribe $course_dir/videos/lesson-" 2>/dev/null || true) | /usr/bin/wc -l | /usr/bin/tr -d ' '
}

wait_for_slot() {
  local active
  local ticks=0
  while true; do
    active=$(active_transcriptions)
    if (( active < max_parallel )); then
      return
    fi
    if (( ticks % 6 == 0 )); then
      print "course=$course_id waiting_for_transcription_slot active=$active"
    fi
    sleep 10
    (( ticks += 1 ))
  done
}

for lesson_number in {$start_lesson..$lesson_count}; do
  lesson_index=$(( lesson_number - 1 ))
  lesson_label=$(printf '%02d' "$lesson_number")
  video="$videos_dir/lesson-$lesson_label.mp4"
  transcript="$transcripts_dir/lesson-$lesson_label.jsonl"
  lesson_frames="$frames_dir/lesson-$lesson_label"
  ocr="$frames_dir/lesson-$lesson_label-ocr.jsonl"
  log="$logs_dir/lesson-$lesson_label.log"
  title=$(/usr/bin/jq -r ".[$lesson_index].title" "$metadata")
  duration=$(/usr/bin/jq -r ".[$lesson_index].duration" "$metadata")

  print "course=$course_id lesson=$lesson_number/$lesson_count stage=download title=$title"
  if [[ ! -s "$video" ]]; then
    lesson_url=$(/usr/bin/jq -r ".[$lesson_index].file" "$metadata")
    /usr/bin/curl -fsSL --retry 3 -A 'Mozilla/5.0' "$lesson_url" -o "$video"
  fi

  if [[ ! -s "$ocr" ]]; then
    mkdir -p "$lesson_frames"
    /usr/bin/seq 0 180 "$duration" | /usr/bin/xargs "$tools_dir/extract-frames" "$video" "$lesson_frames" >/dev/null
    "$tools_dir/ocr-frames" "$lesson_frames" "$ocr" >/dev/null
  fi
  print "course=$course_id lesson=$lesson_number/$lesson_count stage=visual_map_ready"

  if [[ ! -s "$transcript" ]]; then
    wait_for_slot
    /usr/bin/open -W -n "$transcriber_app" --args "$video" "$transcript" ru-RU >"$log" 2>&1 &
    print "course=$course_id lesson=$lesson_number/$lesson_count stage=transcription_started"
  else
    print "course=$course_id lesson=$lesson_number/$lesson_count stage=transcription_already_ready"
  fi
done

ticks=0
while true; do
  active=$(active_transcriptions)
  if (( active == 0 )); then
    break
  fi
  if (( ticks % 6 == 0 )); then
    ready=$(/usr/bin/find "$transcripts_dir" -type f -name 'lesson-*.jsonl' -size +0c | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    print "course=$course_id stage=waiting_for_transcriptions active=$active ready=$ready/$lesson_count"
  fi
  sleep 10
  (( ticks += 1 ))
done

missing=0
for lesson_number in {1..$lesson_count}; do
  lesson_label=$(printf '%02d' "$lesson_number")
  if [[ ! -s "$transcripts_dir/lesson-$lesson_label.jsonl" ]]; then
    print -u2 "course=$course_id lesson=$lesson_number stage=transcription_missing"
    (( missing += 1 ))
  fi
done

if (( missing > 0 )); then
  print -u2 "course=$course_id stage=failed missing_transcripts=$missing"
  exit 1
fi

print "course=$course_id stage=media_processing_complete lessons=$lesson_count"
