#!/usr/bin/env bash
# End-to-end test of meeting transcription on a synthetic two-person call.
#
#   scripts/test-meeting.sh                pass/fail checks (language "Both", so a Hindi line is in it too)
#   scripts/test-meeting.sh --keep         also keep the generated audio and output (path printed)
#
# macOS voices speak a short meeting: "Me" on the mic channel, "Others" on the system-audio channel,
# with pauses, one bit of crosstalk, a Hindi line, a long turn of the others with two short replies
# over it, and a faint, slightly delayed copy of the others in the mic (what a laptop mic hears
# without headphones). It then runs the real pipeline headless
# (VoiceType --meeting: WAVs, VAD per channel, live chunks, whisper.cpp, filters, echo de-dup, merge)
# and checks speakers, words, order, the echo and the timing line.
# Models: the app's shared folder, or MODELS=/path/to/models.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODELS="${MODELS:-$HOME/Library/Application Support/VoiceType/Models}"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1
swift build -c release --arch arm64 2>&1 | grep -E "error|Build complete" >&2
BIN="$(swift build -c release --arch arm64 --show-bin-path)/VoiceType"

for v in Samantha Daniel Lekha; do
  say -v '?' | grep -q "^$v " || { echo "macOS voice $v is not installed (System Settings → Accessibility → Spoken Content)." >&2; exit 2; }
done

TMP="$(mktemp -d)"
if [[ $KEEP -eq 0 ]]; then trap 'rm -rf "$TMP"' EXIT; else echo "keeping $TMP" >&2; fi

# speaker <TAB> start second <TAB> voice <TAB> text
cat >"$TMP/script.tsv" <<'EOF'
me	0.5	Samantha	Good morning everyone. Let's start the weekly sync for the payments project.
others	6.5	Daniel	Morning! I finished the invoice export last night, and all the tests are green.
me	13.5	Samantha	Great. Can you ship it to staging today, before the release review?
others	20	Daniel	Yes, I will deploy it by four o'clock. One open question: who owns the refund report?
me	27.5	Samantha	I will take the refund report. Priya can help with the database migration.
others	29	Daniel	Sounds good.
me	41	Samantha	Let's also decide on the launch date. I propose the twelfth of December.
others	47.5	Daniel	Agreed, the twelfth of December works for marketing.
others	53.5	Lekha	कल की मीटिंग में डिज़ाइन पर बात करेंगे।
me	59	Samantha	Perfect, thanks everyone. Talk to you next week.
others	65	Daniel	So I think the main thing is that we need to get the export out before the review, and I know that it is not going to be easy, but if we can do the migration first then the rest of it should be fine. What I want to do is make sure that you and I are on the same page about that.
me	72	Samantha	Yes, we can do that.
me	79	Samantha	That should be fine.
EOF

n=0
while IFS=$'\t' read -r _ _ voice text; do
  say -v "$voice" -o "$TMP/line$n.wav" --data-format=LEI16@16000 "$text"
  n=$((n + 1))
done <"$TMP/script.tsv"

# Mix the lines into mic.wav and system.wav; the mic also gets the others at -16 dB, 30 ms late.
cat >"$TMP/mix.py" <<'EOF'
import array, sys, wave
tmp = sys.argv[1]
rate = 16000
rows = [l.rstrip("\n").split("\t") for l in open(f"{tmp}/script.tsv", encoding="utf-8") if l.strip()]
clips = []
for i, (who, start, _, _) in enumerate(rows):
    with wave.open(f"{tmp}/line{i}.wav") as w:
        assert w.getframerate() == rate and w.getnchannels() == 1 and w.getsampwidth() == 2
        clips.append((who, int(float(start) * rate), array.array("h", w.readframes(w.getnframes()))))
total = max(s + len(c) for _, s, c in clips) + 2 * rate
chan = {"me": [0.0] * total, "others": [0.0] * total}
for who, s, c in clips:
    buf = chan[who]
    for j, v in enumerate(c):
        buf[s + j] += v
delay, gain = int(0.03 * rate), 0.16
mic = [m + gain * (chan["others"][i - delay] if i >= delay else 0) for i, m in enumerate(chan["me"])]
def write(name, data):
    with wave.open(f"{tmp}/{name}", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(array.array("h", (max(-32768, min(32767, int(v))) for v in data)).tobytes())
write("mic.wav", mic)
write("system.wav", chan["others"])
print(f"{total / rate:.1f}")
EOF
SECONDS_LONG="$(python3 -I "$TMP/mix.py" "$TMP")"
echo "synthetic meeting: ${SECONDS_LONG}s, two channels" >&2

run() { # run <outdir> [flags...]
  VOICETYPE_VAD="$ROOT/vendor/silero_vad.onnx" DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib \
    "$BIN" --meeting "$TMP/mic.wav" "$TMP/system.wav" "$MODELS" auto --out "$1" "${@:2}" 2>/dev/null
}

OUT="$(run "$TMP/out")"
MD="$TMP/out/transcript.md"
echo "$OUT" | sed -n '/^## Transcript/,/^MEETING/p'

fails=0
check() { # check <name> <ok?> [detail]
  if [[ "$2" == yes ]]; then echo "ok    $1${3:+: $3}"; else echo "FAIL  $1${3:+: $3}"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo yes; else echo no; fi; }
not() { ! "$@"; }
said() { grep -E "^\[[0-9:]{8}\] \*\*$1:\*\*" "$MD" | grep -qi "$2"; }
not_said() { ! said "$@"; }

[[ -f "$MD" ]] || { echo "FAIL  no transcript.md"; exit 1; }
check "Me and Others both transcribed" "$(yes_if grep -q '\*\*Others:\*\*' "$MD")"
for w in "weekly sync" "staging" "refund report" "December" "next week"; do check "Me said \"$w\"" "$(yes_if said Me "$w")"; done
for w in "invoice export" "o'clock" "sounds good" "marketing"; do check "Others said \"$w\"" "$(yes_if said Others "$w")"; done
check "Hindi line in Latin script (Hinglish)" "$(yes_if said Others "kal\|meeting\|design")" "$(grep -iE 'kal|design' "$MD" | head -1 | cut -c1-90)"
check "no Devanagari left" "$(yes_if not grep -q '[ऀ-ॿ]' "$MD")"
for w in "invoice export" "marketing"; do check "echo of \"$w\" not attributed to Me" "$(yes_if not_said Me "$w")"; done
# Short replies during a long turn share common words with it; the echo filter must keep them.
for w in "we can do that" "should be fine"; do check "my reply \"$w\" kept during their long turn" "$(yes_if said Me "$w")"; done
STAMPS="$(grep -oE '^\[[0-9:]{8}\]' "$MD" | tr -d '[]')"
check "timestamps in order" "$(yes_if test "$STAMPS" == "$(sort <<<"$STAMPS")")"
LAST="$(grep -i 'next week' "$MD" | grep -oE '^\[[0-9:]{8}\]' | tr -d '[]' | head -1)"
check "timestamps on the meeting clock (\"next week\" line near 0:59)" "$(yes_if grep -qE '^00:00:(5[4-9]|6[0-4])$' <<<"$LAST")" "$LAST"
check "transcript.json and meeting.json written" "$(yes_if test -s "$TMP/out/transcript.json" -a -s "$TMP/out/meeting.json")"
check "meeting.json says ready" "$(yes_if grep -q '"status" : "ready"' "$TMP/out/meeting.json")"
check "audio was written to disk" "$(yes_if test -s "$TMP/out/mic.wav" -a -s "$TMP/out/system.wav")"
TIMING="$(grep '^MEETING' <<<"$OUT" || true)"
check "timing line" "$(yes_if test -n "$TIMING")"

# Without the echo filter, how much of the others' voice did the mic channel pick up? (information)
NOECHO="$(run "$TMP/out-noecho" --no-echo-filter | grep -c '^\[[0-9:]*\] \*\*Me:\*\*.*\(invoice\|marketing\|four o\)' || true)"
echo "info  without the echo filter, $NOECHO Me line(s) repeat the others"
echo "$TIMING" | tr '\t' '\n' | grep -E '^(engine|audio|speech|chunks|decode|RTF|speechRTF|tail|load|words|echoRemoved)=' | sed 's/^/info  /'

[[ $fails -eq 0 ]] && echo "All meeting checks passed." || { echo "$fails meeting check(s) failed." >&2; exit 1; }
