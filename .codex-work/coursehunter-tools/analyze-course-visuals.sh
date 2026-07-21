#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: analyze-course-visuals.sh COURSE_ID PARALLEL" >&2
  exit 64
fi

course_id=$1
parallel=$2
root=".codex-work/coursehunter-${course_id}"
metadata="${root}/lessons.json"
video_dir="${root}/videos"
frame_root="${root}/frames"
ocr_root="${root}/ocr"
log_root="${root}/visual-logs"
tool_root=".codex-work/coursehunter-tools"

[[ -s "$metadata" ]] || { echo "metadata not found" >&2; exit 66; }
[[ -x "${tool_root}/extract-frames" && -x "${tool_root}/ocr-frames" ]] || {
  echo "visual tools are not executable" >&2
  exit 66
}
mkdir -p "$frame_root" "$ocr_root" "$log_root"
export course_id root metadata video_dir frame_root ocr_root log_root tool_root

seq 1 "$(jq 'length' "$metadata")" |
  xargs -n 1 -P "$parallel" bash -c '
    set -euo pipefail
    lesson=$1
    video=$(printf "%s/lesson-%03d.mp4" "$video_dir" "$lesson")
    frame_dir=$(printf "%s/lesson-%03d" "$frame_root" "$lesson")
    ocr_file=$(printf "%s/lesson-%03d.jsonl" "$ocr_root" "$lesson")
    log_file=$(printf "%s/lesson-%03d.log" "$log_root" "$lesson")
    [[ -s "$video" ]] || { echo "missing video for lesson $lesson" >&2; exit 1; }
    if [[ -s "$ocr_file" ]]; then
      printf "lesson %03d visuals already analyzed\n" "$lesson"
      exit 0
    fi

    title=$(jq -r --argjson i "$lesson" ".[\$i-1].title" "$metadata")
    duration=$(jq -r --argjson i "$lesson" ".[\$i-1].duration" "$metadata")
    interval=60
    if [[ "$title" =~ (Вопросы[[:space:]]+и[[:space:]]+ответы|Q\&A|QA-сессия) ]]; then
      interval=90
    elif [[ "$title" =~ (Задач|Разбор|Практик|Проектирован|реализац|ошиб|Lock-free|Алгоритм|Операц|Структур|Асимптот|Массив|Список|Стек|Очеред|Дерев|Куч|Хеш|Squares|Worker|Batcher|Cache|домашн) ]]; then
      interval=30
    fi

    mkdir -p "$frame_dir"
    if (( duration <= 20 )); then
      timestamps=("$(( duration / 2 ))")
    else
      last=$(( duration - 5 ))
      midpoint=$(( duration / 2 ))
      timestamps=()
      while IFS= read -r timestamp; do
        timestamps+=("$timestamp")
      done < <(
        { printf "5\n%d\n%d\n" "$midpoint" "$last"; seq 5 "$interval" "$last"; } |
          sort -n -u
      )
    fi

    {
      "${tool_root}/extract-frames" "$video" "$frame_dir" "${timestamps[@]}"
      "${tool_root}/ocr-frames" "$frame_dir" "$ocr_file"
    } >"$log_file" 2>&1
    frames=$(find "$frame_dir" -maxdepth 1 -type f -name "*.jpg" | wc -l | tr -d " ")
    records=$(wc -l < "$ocr_file" | tr -d " ")
    [[ "$frames" -gt 0 && "$records" -eq "$frames" ]] || {
      echo "lesson $lesson visual validation failed: frames=$frames records=$records" >&2
      exit 1
    }
    printf "lesson %03d analyzed (%d frames, interval %ds)\n" "$lesson" "$frames" "$interval"
  ' _

expected=$(jq 'length' "$metadata")
actual=$(find "$ocr_root" -maxdepth 1 -type f -name 'lesson-*.jsonl' -size +0 | wc -l | tr -d ' ')
[[ "$actual" -eq "$expected" ]] || { echo "visual analysis incomplete: $actual/$expected" >&2; exit 1; }
echo "visual analysis complete: $actual lessons"
