#!/bin/zsh

set -euo pipefail

if (( $# != 2 )); then
  print -u2 "usage: compare-course-pair.sh <7171-lesson> <6546-lesson>"
  exit 64
fi

source_lesson=$1
reference_lesson=$2
source_video=$(printf '.codex-work/coursehunter-7171/compare/lesson-%03d.mp4' "$source_lesson")
reference_frames=$(printf '.codex-work/coursehunter-6546/frames/lesson-%03d' "$reference_lesson")
target_frames=$(printf '.codex-work/coursehunter-7171/compare-frames/lesson-%03d' "$reference_lesson")
target_ocr=$(printf '.codex-work/coursehunter-7171/compare-ocr/lesson-%03d.jsonl' "$reference_lesson")

[[ -s "$source_video" ]] || { print -u2 "missing source video: $source_video"; exit 66; }
[[ -d "$reference_frames" ]] || { print -u2 "missing reference frames: $reference_frames"; exit 66; }

mkdir -p "$target_frames" "${target_ocr:h}"
timestamps=()
for frame in "$reference_frames"/frame-*.jpg(N); do
  name=${frame:t}
  millis=${name#frame-}
  millis=${millis%.jpg}
  timestamps+=("$(awk -v value="$millis" 'BEGIN { printf "%.3f", value / 1000 }')")
done

(( ${#timestamps} > 0 )) || { print -u2 "no reference timestamps: $reference_frames"; exit 66; }

.codex-work/coursehunter-tools/extract-frames "$source_video" "$target_frames" "${timestamps[@]}" >/dev/null
.codex-work/coursehunter-tools/ocr-frames "$target_frames" "$target_ocr" >/dev/null

expected=${#timestamps}
actual=$(wc -l < "$target_ocr" | tr -d ' ')
[[ "$actual" -eq "$expected" ]] || {
  print -u2 "OCR mismatch for pair $source_lesson:$reference_lesson: expected=$expected actual=$actual"
  exit 1
}

printf 'pair %03d:%03d compared (%d frames)\n' "$source_lesson" "$reference_lesson" "$actual"
