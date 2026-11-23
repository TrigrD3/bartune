#!/usr/bin/env bash
# Downloads JamendoLyrics MultiLang for the alignment eval (AlignmentEvalTests) and converts its audio
# to the 16 kHz stereo the app captures. The audio is Creative Commons: keep it out of the repo.
#
#   scripts/fetch-jamendolyrics.sh <dir> [Language ...]    e.g. <dir> English
#   BARTUNE_EVAL_DIR=<dir> swift test --filter AlignmentEvalTests
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <dir> [English|German|Spanish|French ...]" >&2
    exit 2
fi
DIR="$1"
shift
REVISION="de188c963fd4539bc769b3feb83582e5a9595e36"
BASE="https://huggingface.co/datasets/jamendolyrics/jamendolyrics/resolve/$REVISION"

mkdir -p "$DIR"/{lines,words,wav,mp3}
curl -sfL "$BASE/JamendoLyrics.csv" -o "$DIR/JamendoLyrics.csv"

# "<stem> <language code>" per song in the chosen languages (all songs when none is given).
STEMS=$(python3 -I - "$DIR/JamendoLyrics.csv" "$@" <<'EOF'
import csv, sys
codes = {"English": "en", "German": "de", "Spanish": "es", "French": "fr"}
languages = set(sys.argv[2:])
for row in csv.DictReader(open(sys.argv[1], encoding="utf-8")):
    if not languages or row["Language"] in languages:
        print(row["Filepath"].removesuffix(".mp3"), codes[row["Language"]])
EOF
)

count=0
while read -r stem code; do
    [[ -z "$stem" ]] && continue
    count=$((count + 1))
    encoded=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$stem")
    if [[ -f "$DIR/wav/$stem.wav" ]]; then
        echo "[$count] $stem (already fetched)"
        continue
    fi
    echo "[$count] $stem"
    curl -sfL "$BASE/annotations/lines/$encoded.csv" -o "$DIR/lines/$stem.csv"
    curl -sfL "$BASE/annotations/words/$encoded.csv" -o "$DIR/words/$stem.csv"
    # mp3/ holds symlinks into subsets/<code>/mp3/, which the download URL doesn't follow.
    curl -sfL "$BASE/subsets/$code/mp3/$encoded.mp3" -o "$DIR/mp3/$stem.mp3"
    afconvert -f WAVE -d LEF32@16000 -c 2 "$DIR/mp3/$stem.mp3" "$DIR/wav/$stem.wav"
    rm "$DIR/mp3/$stem.mp3"
done <<< "$STEMS"
echo "Fetched $count songs into $DIR"
