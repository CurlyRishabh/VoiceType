#!/usr/bin/env bash
# Real-audio accuracy + speed benchmark for the Mac speech engines.
#
#   scripts/bench-asr.sh [--n 100] [--sets clean,other,hindi] [--models ../models]
#                        [--cv <common-voice-folder> --cv-lang hi]
#
# Datasets (downloaded once into mac/bench-data/, checksum-verified):
#   clean  LibriSpeech test-clean   English audiobooks, clear speech      (347 MB, openslr.org/12)
#   other  LibriSpeech test-other   English, harder speakers/recordings   (329 MB, openslr.org/12)
#   hindi  Google FLEURS hi_in test Real Hindi speech, read Wikipedia      (249 MB, CC-BY-4.0)
#   cv     Mozilla Common Voice     Accents, everyday speech. Not downloadable automatically:
#          get a language from https://datacollective.mozillafoundation.org (free account),
#          extract it, and pass the folder that holds test.tsv and clips/ with --cv.
#
# Engines: whisper.cpp (if a ggml-*.bin model is found), Moonshine and sherpa-onnx Whisper (if
# their files are found). Each set uses --n clips spread evenly across speakers.
# Reports corpus word error rate (WER), character error rate (CER) and real-time factor (RTF:
# decode time / audio length) per engine. Results: mac/bench-data/results/.
# Set VOICETYPE_PROMPT="Term, Term" to benchmark the whisper.cpp vocabulary prompt too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N=100
SETS="clean,other,hindi"
MODELS="$ROOT/../models"
CV="" ; CV_LANG="hi"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --n) N="$2"; shift 2 ;;
    --sets) SETS="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --cv) CV="$2"; SETS="$SETS,cv"; shift 2 ;;
    --cv-lang) CV_LANG="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

DATA="$ROOT/bench-data"
OUT="$DATA/results"
mkdir -p "$DATA/downloads" "$OUT"
FLEURS_REV="70bb2e84b976b7e960aa89f1c648e09c59f894dd"

# fetch <url> <file> <md5|sha256> <hash>
fetch() {
  local url="$1" file="$DATA/downloads/$2" algo="$3" want="$4" got
  if [[ ! -f "$file" ]]; then
    echo "==> downloading $2"
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if [[ "$algo" == md5 ]]; then got="$(md5 -q "$file")"; else got="$(shasum -a 256 "$file" | awk '{print $1}')"; fi
  [[ "$got" == "$want" ]] || { echo "checksum mismatch for $2 (delete it and retry)" >&2; rm -f "$file"; exit 1; }
}

has_set() { [[ ",$SETS," == *",$1,"* ]]; }

# ---------- datasets -> manifests ("audio path<TAB>reference" per line) ----------
manifest_librispeech() { # <test-clean|test-other> <md5>
  local name="$1"
  fetch "https://www.openslr.org/resources/12/$name.tar.gz" "$name.tar.gz" md5 "$2"
  if [[ ! -d "$DATA/LibriSpeech/$name" ]]; then tar xzf "$DATA/downloads/$name.tar.gz" -C "$DATA"; fi
  python3 -I - "$DATA/LibriSpeech/$name" "$N" > "$DATA/$name.tsv" <<'PY'
import glob, os, sys
root, n = sys.argv[1], int(sys.argv[2])
rows = []
for trans in sorted(glob.glob(os.path.join(root, "*", "*", "*.trans.txt"))):
    d = os.path.dirname(trans)
    for line in open(trans, encoding="utf-8"):
        uid, text = line.rstrip("\n").split(" ", 1)
        rows.append((os.path.join(d, uid + ".flac"), text))
step = max(1, len(rows) // n)          # spread across all speakers
for path, text in rows[::step][:n]:
    print(f"{path}\t{text}")
PY
}

manifest_fleurs_hindi() {
  local base="https://huggingface.co/datasets/google/fleurs/resolve/$FLEURS_REV/data/hi_in"
  fetch "$base/audio/test.tar.gz" "fleurs-hi_in-test.tar.gz" sha256 47c238b9cf7016ba596639bb3038b0c89dc6e85759f16d09c4f58c6dfa25c65f
  fetch "$base/test.tsv" "fleurs-hi_in-test.tsv" sha256 889e82e2875490f9533ff59ab67326fcfa01cf828fc4412758aaaa1f442a729f
  if [[ ! -d "$DATA/fleurs-hi_in" ]]; then
    mkdir -p "$DATA/fleurs-hi_in"
    tar xzf "$DATA/downloads/fleurs-hi_in-test.tar.gz" -C "$DATA/fleurs-hi_in"
  fi
  python3 -I - "$DATA/fleurs-hi_in" "$DATA/downloads/fleurs-hi_in-test.tsv" "$N" > "$DATA/fleurs-hi_in.tsv" <<'PY'
import os, sys
root, tsv, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
wavs = {}
for d, _, files in os.walk(root):
    for f in files:
        if f.endswith(".wav"): wavs[f] = os.path.join(d, f)
rows = []
for line in open(tsv, encoding="utf-8"):
    cols = line.rstrip("\n").split("\t")
    if len(cols) >= 4 and cols[1] in wavs:
        rows.append((wavs[cols[1]], cols[3]))     # column 4: normalised transcription
step = max(1, len(rows) // n)
for path, text in rows[::step][:n]:
    print(f"{path}\t{text}")
PY
}

manifest_common_voice() {
  [[ -f "$CV/test.tsv" && -d "$CV/clips" ]] || { echo "--cv must be a Common Voice language folder with test.tsv and clips/" >&2; exit 1; }
  python3 -I - "$CV" "$N" > "$DATA/common-voice.tsv" <<'PY'
import csv, os, sys
root, n = sys.argv[1], int(sys.argv[2])
rows = []
with open(os.path.join(root, "test.tsv"), encoding="utf-8") as f:
    for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
        p = os.path.join(root, "clips", r["path"])
        if os.path.exists(p) and r.get("sentence"):
            rows.append((p, r["sentence"].replace("\t", " ")))
step = max(1, len(rows) // n)
for path, text in rows[::step][:n]:
    print(f"{path}\t{text}")
PY
}

# ---------- model folders (APFS clones: no extra disk space) ----------
MCPP="$DATA/models-cpp" ; MONNX="$DATA/models-onnx"
rm -rf "$MCPP" "$MONNX"; mkdir -p "$MCPP/vad" "$MCPP/whisper" "$MONNX/vad" "$MONNX/whisper" "$MONNX/moonshine"
VAD="$(ls "$MODELS"/vad/*.onnx 2>/dev/null | head -1 || true)"
[[ -n "$VAD" ]] || { "$ROOT/scripts/fetch-vad.sh" >/dev/null; VAD="$ROOT/vendor/silero_vad.onnx"; }
cp -c "$VAD" "$MCPP/vad/"; cp -c "$VAD" "$MONNX/vad/"
GGML="$(ls "$MODELS"/whisper-cpp/*.bin "$MODELS"/whisper/*.bin 2>/dev/null | head -1 || true)"
[[ -n "$GGML" ]] && cp -c "$GGML" "$MCPP/whisper/"
for f in "$MODELS"/whisper/*.onnx "$MODELS"/whisper/*tokens.txt; do [[ -f "$f" ]] && cp -c "$f" "$MONNX/whisper/"; done
for f in "$MODELS"/moonshine/*; do [[ -f "$f" ]] && cp -c "$f" "$MONNX/moonshine/"; done
HAVE_ONNX_WHISPER=$([[ -n "$(ls "$MONNX"/whisper/*encoder*.onnx 2>/dev/null)" && -n "$(ls "$MONNX"/whisper/*tokens.txt 2>/dev/null)" ]] && echo 1 || echo 0)
HAVE_MOONSHINE=$([[ -f "$MONNX/moonshine/tokens.txt" ]] && echo 1 || echo 0)
HAVE_CPP=$([[ -n "$GGML" ]] && echo 1 || echo 0)
echo "==> engines: whisper.cpp=$HAVE_CPP moonshine=$HAVE_MOONSHINE sherpa-whisper=$HAVE_ONNX_WHISPER (models from $MODELS)"

# ---------- build ----------
echo "==> building"
(cd "$ROOT" && scripts/fetch-sherpa.sh >/dev/null && scripts/fetch-whisper-cpp.sh >/dev/null && swift build -c release --arch arm64 2>&1 | tail -1)
BIN="$(cd "$ROOT" && swift build -c release --arch arm64 --show-bin-path)/VoiceType"
export DYLD_LIBRARY_PATH="$ROOT/vendor/sherpa-onnx/lib"

# ---------- run ----------
SUMMARY="$OUT/summary.tsv"
: > "$SUMMARY"
run() { # <set label> <manifest> <lang> <engine> <models dir> <tag>
  echo "==> $1 · $6"
  local line
  line="$("$BIN" --bench "$2" "$5" "$3" "$4" "$OUT/$1-$6.tsv" | grep '^SUMMARY' || true)"
  [[ -n "$line" ]] || { echo "   failed (see above)"; return; }
  echo "$1	$line" >> "$SUMMARY"
}
engines_for() { # <set> <manifest> <lang>
  [[ $HAVE_CPP == 1 ]] && run "$1" "$2" "$3" whisper "$MCPP" whisper-cpp
  [[ $HAVE_ONNX_WHISPER == 1 ]] && run "$1" "$2" "$3" whisper "$MONNX" whisper-onnx
  [[ $3 == en && $HAVE_MOONSHINE == 1 ]] && run "$1" "$2" "$3" moonshine "$MONNX" moonshine
  return 0
}

has_set clean && { manifest_librispeech test-clean 32fa31d27d2e1cad72775fee3f4849a9; engines_for librispeech-clean "$DATA/test-clean.tsv" en; }
has_set other && { manifest_librispeech test-other fb5a50374b501bb3bac4815ee91d3135; engines_for librispeech-other "$DATA/test-other.tsv" en; }
has_set hindi && { manifest_fleurs_hindi; engines_for fleurs-hindi "$DATA/fleurs-hi_in.tsv" hi; }
has_set cv && [[ -n "$CV" ]] && { manifest_common_voice; engines_for "common-voice-$CV_LANG" "$DATA/common-voice.tsv" "$CV_LANG"; }

# ---------- report ----------
python3 -I - "$SUMMARY" "$OUT/summary.md" "$N" <<'PY'
import sys
src, dst, n = sys.argv[1], sys.argv[2], sys.argv[3]
lines = ["| Dataset | Engine | Clips | Audio | WER | CER | Speed (RTF) | Prompt |", "|---|---|---|---|---|---|---|---|"]
for row in open(src, encoding="utf-8"):
    cols = row.rstrip("\n").split("\t")
    kv = dict(c.split("=", 1) for c in cols[2:] if "=" in c)
    lines.append(f"| {cols[0]} | {kv['engine']} | {kv['clips']} | {kv['audio']} | **{float(kv['WER']):.1f}%** | {float(kv['CER']):.1f}% | {kv['RTF']} | {kv['prompt']} |")
report = "\n".join(lines) + "\n\nWER/CER: lower is better. RTF: decode time / audio length (0.05 = 20x faster than real time).\n"
open(dst, "w", encoding="utf-8").write(report)
print(report)
PY
echo "Per-clip results (reference vs hypothesis): $OUT/"
