#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: download-course.sh COURSE_ID COOKIE_SOURCE PARALLEL" >&2
  exit 64
fi

course_id=$1
cookie_source=$2
parallel=$3
root=".codex-work/coursehunter-${course_id}"
metadata="${root}/lessons.json"
video_dir="${root}/videos"

[[ -s "$metadata" ]] || { echo "metadata not found: $metadata" >&2; exit 66; }
[[ -s "$cookie_source" ]] || { echo "cookie source not found" >&2; exit 66; }
[[ "$parallel" =~ ^[1-9][0-9]*$ ]] || { echo "parallel must be positive" >&2; exit 64; }

course_cookie=$(awk -F"'" '/^[[:space:]]*-b / {print $2; exit}' "$cookie_source")
[[ -n "$course_cookie" ]] || { echo "cookie was not found" >&2; exit 65; }
export course_cookie video_dir
mkdir -p "$video_dir"

jq -j 'to_entries[] | ((.key + 1) | tostring), "\u0000", .value.file, "\u0000"' "$metadata" |
  xargs -0 -n 2 -P "$parallel" bash -c '
    set -euo pipefail
    lesson=$1
    url=$2
    target=$(printf "%s/lesson-%03d.mp4" "$video_dir" "$lesson")
    part="${target}.part"
    if [[ -s "$target" ]]; then
      printf "lesson %03d already present\n" "$lesson"
      exit 0
    fi
    curl --fail --silent --show-error --location \
      --retry 4 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
      -b "$course_cookie" -o "$part" "$url"
    [[ -s "$part" ]] || { echo "empty download for lesson $lesson" >&2; exit 1; }
    mv "$part" "$target"
    bytes=$(stat -f %z "$target")
    printf "lesson %03d downloaded (%d bytes)\n" "$lesson" "$bytes"
  ' _

expected=$(jq 'length' "$metadata")
actual=$(find "$video_dir" -maxdepth 1 -type f -name 'lesson-*.mp4' | wc -l | tr -d ' ')
partial=$(find "$video_dir" -maxdepth 1 -type f -name '*.part' | wc -l | tr -d ' ')
[[ "$actual" -eq "$expected" && "$partial" -eq 0 ]] || {
  echo "download validation failed: expected=$expected actual=$actual partial=$partial" >&2
  exit 1
}
echo "download complete: $actual lessons"
