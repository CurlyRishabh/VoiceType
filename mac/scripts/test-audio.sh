#!/usr/bin/env bash
# Runs audio through the real speech stack (VAD, chunking, Whisper, clean-up rules; no AI polish).
#
#   scripts/test-audio.sh                 built-in checks on clips spoken by macOS voices (pass/fail)
#   scripts/test-audio.sh a.wav b.m4a     shows what each clip types in every language/translate mode
#
# Any format Core Audio reads works (wav, m4a, mp3, flac). App recordings, when "Keep recordings"
# is on, are in ~/Library/Containers/dev.offline.voicetype.mac/Data/Library/Application Support/VoiceType/recordings
# Models: the app's shared folder, or MODELS=/path/to/models.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODELS="${MODELS:-$HOME/Library/Application Support/VoiceType/Models}"
swift build --arch arm64 2>&1 | grep -E "error|Build complete" >&2
BIN="$(swift build --arch arm64 --show-bin-path)/VoiceType"

# run <audio> <en|hi|auto> [--translate] [--devanagari]  ->  "RAW<TAB>CLEANED"
run() {
  local out
  out="$(DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib "$BIN" --selftest "$MODELS" "$1" "$2" whisper "${@:3}" 2>/dev/null)"
  printf '%s\t%s\n' "$(sed -n 's/^RAW: *//p' <<<"$out")" "$(sed -n 's/^CLEANED: *//p' <<<"$out")"
}

MODES=("en" "hi" "hi --devanagari" "auto" "auto --translate" "hi --translate")

if [[ $# -gt 0 ]]; then
  for f in "$@"; do
    echo "== $f"
    for m in "${MODES[@]}"; do
      # shellcheck disable=SC2086
      printf '  %-18s %s\n' "$m" "$(run "$f" $m | cut -f2)"
    done
  done
  exit 0
fi

has_devanagari() { python3 -I -c 'import sys,re; sys.exit(0 if re.search("[ऀ-ॿ]", sys.argv[1]) else 1)' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for v in Lekha Rishi; do
  say -v '?' | grep -q "^$v " || { echo "macOS voice $v is not installed (System Settings → Accessibility → Spoken Content)." >&2; exit 2; }
done
say -v Lekha -o "$TMP/hindi.wav" --data-format=LEI16@16000 "कल मीटिंग है, प्लीज़ आ जाना भाई लोग"
say -v Rishi -o "$TMP/english.wav" --data-format=LEI16@16000 "The meeting is tomorrow, please come on time"

fails=0
check() { # check <name> <ok?> <output>
  if [[ "$2" == yes ]]; then echo "ok    $1: $3"; else echo "FAIL  $1: $3"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo yes; else echo no; fi; }
not() { ! "$@"; }

IFS=$'\t' read -r raw typed < <(run "$TMP/hindi.wav" hi)
check "Hindi → Hinglish (Latin)"        "$(yes_if not has_devanagari "$typed")" "$typed"
IFS=$'\t' read -r raw typed < <(run "$TMP/hindi.wav" hi --devanagari)
check "Hindi → Devanagari"              "$(yes_if has_devanagari "$typed")" "$typed"
IFS=$'\t' read -r raw typed < <(run "$TMP/hindi.wav" auto --translate)
check "Hindi, Both + translate → English" "$(yes_if not has_devanagari "$raw")" "$typed"
IFS=$'\t' read -r raw typed < <(run "$TMP/hindi.wav" hi --translate)
check "Hindi, Hindi + translate → English" "$(yes_if not has_devanagari "$raw")" "$typed"
IFS=$'\t' read -r raw typed < <(run "$TMP/english.wav" auto)
check "English, Both → English"         "$(yes_if grep -qi meeting <<<"$typed")" "$typed"
IFS=$'\t' read -r raw typed < <(run "$TMP/english.wav" auto --translate)
check "English, Both + translate → English" "$(yes_if grep -qi meeting <<<"$typed")" "$typed"

[[ $fails -eq 0 ]] && echo "All audio checks passed." || { echo "$fails audio check(s) failed." >&2; exit 1; }
