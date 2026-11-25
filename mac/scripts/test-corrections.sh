#!/bin/bash
# Learning from corrections, end to end on real text fields, through the app's own code
# (VoiceType --corrections: read the focused field, paste with ⌘V, watch with CorrectionWatch).
# For each app it pastes "Let's send this draft to Shashi", then deletes "Shashi" with ⌫,
# types "Sasi", and either leaves the field (another app comes to the front) or presses Return in a
# chat box that clears itself, like Slack or T3. Expect: LEARNED Shashi→Sasi every time.
#
#   scripts/test-corrections.sh [textedit] [chrome] [electron]     (default: all three)
#
# Needs Accessibility for the terminal that runs it. Takes over the keyboard for a few seconds per
# app; don't type meanwhile. "electron" needs ELECTRON=/path/to/Electron.app/Contents/MacOS/Electron
# (e.g. from `npm i electron`): chat boxes in Electron like Slack's and T3 Code's (one bare line, an
# empty box that reads as a line break, and text on a line above).
# Nothing is added to your Dictionary: the headless check only prints what it would learn.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
swift build -c release --arch arm64 >/dev/null 2>&1 || { echo "build failed"; exit 1; }
BIN="$(swift build -c release --arch arm64 --show-bin-path)/VoiceType"
TEXT="Let's send this draft to Shashi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0

front() { osascript -e 'tell application "System Events" to name of first application process whose frontmost is true'; }

# $1 label, $2 process name that must be in front, $3 how to finish (leave|return)
run() {
  local label=$1 proc=$2 finish=$3 out="$WORK/$1.out"
  osascript -e "tell application \"System Events\" to set frontmost of process \"$proc\" to true" 2>/dev/null
  sleep 1
  if [ "$(front)" != "$proc" ]; then echo "SKIP $label: $proc is not in front ($(front))"; fail=1; return; fi
  DYLD_LIBRARY_PATH="$ROOT/vendor/sherpa-onnx/lib" "$BIN" --corrections "$TEXT" 25 >"$out" 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do grep -q "PASTED\|FIELD none\|PASTE copied" "$out" && break; sleep 0.1; done
  sleep 1.2
  if grep -q PASTED "$out"; then
    osascript -e 'tell application "System Events"' -e 'repeat 6 times' -e 'key code 51' -e 'delay 0.05' -e 'end repeat' -e 'keystroke "Sasi"' -e 'end tell'
    sleep 0.6 # fixed, then sent or left right away (the watch reads the field every 0.3 s)
    if [ "$finish" = return ]; then
      osascript -e 'tell application "System Events" to key code 36'
    else
      osascript -e 'tell application "Finder" to activate'
    fi
  fi
  wait $pid
  local got; got=$(grep "^LEARNED\|^FIELD none\|^PASTE" "$out" | tail -1)
  if grep -q "^LEARNED Shashi→Sasi" "$out"; then echo "PASS $label ($finish): $got"; else echo "FAIL $label ($finish): $got"; cat "$out"; fail=1; fi
}

targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=(textedit chrome electron)
for t in "${targets[@]}"; do
  case $t in
  textedit)
    osascript -e 'tell application "TextEdit"' -e 'activate' -e 'make new document' -e 'end tell' >/dev/null
    run textedit TextEdit leave
    osascript -e 'tell application "TextEdit" to close (every document whose modified is true) saving no' 2>/dev/null
    ;;
  chrome)
    page="data:text/html,<title>VoiceType test</title><textarea id=t autofocus style='width:90%25;height:200px'></textarea><script>t.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();t.value=''}}</script>"
    osascript -e 'tell application "Google Chrome"' -e 'make new window' -e "set URL of active tab of front window to \"$page\"" -e 'activate' -e 'end tell' >/dev/null
    sleep 1.5
    run chrome "Google Chrome" return
    osascript -e 'tell application "Google Chrome" to close (every window whose title of active tab is "VoiceType test")' 2>/dev/null
    ;;
  electron)
    if [ -z "${ELECTRON:-}" ]; then echo "SKIP electron: set ELECTRON"; continue; fi
    mkdir -p "$WORK/app"
    # A chat box like Slack's or T3 Code's: rich text in paragraphs, Return sends and empties it.
    #   plain: one bare line.  empty-line: an empty box reads as a lone line break (the paste must
    #   be found by its text).  second-line: text on a line above (Chromium's cursor is one short
    #   per line break above it).
    cat >"$WORK/app/main.js" <<'JS'
const { app, BrowserWindow } = require('electron')
app.whenReady().then(() => {
  const w = new BrowserWindow({ width: 700, height: 300 })
  w.loadURL('data:text/html,' + encodeURIComponent(`<title>VoiceType test</title>
    <div id=t contenteditable style="border:1px solid #888;min-height:120px;padding:8px"></div>
    <script>
      const mode = '${process.env.VT_MODE}', empty = mode === 'plain' ? '' : '<p><br></p>'
      t.innerHTML = mode === 'second-line' ? '<p>Hi, my name is Rishabh.</p><p>Hi.</p>' : empty
      t.focus()
      const last = t.lastElementChild || t, r = document.createRange(), n = last.firstChild
      if (n && n.nodeType === 3) r.setStart(n, n.length); else r.setStart(last, 0)
      getSelection().removeAllRanges(); getSelection().addRange(r)
      t.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); t.innerHTML = empty } }
    </script>`))
})
JS
    echo '{"name":"vt-test","main":"main.js"}' >"$WORK/app/package.json"
    for mode in plain empty-line second-line; do
      VT_MODE=$mode "$ELECTRON" "$WORK/app" >/dev/null 2>&1 &
      epid=$!
      sleep 3
      osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$epid"') to true'
      run "electron-$mode" Electron return
      kill $epid 2>/dev/null
      wait $epid 2>/dev/null
    done
    ;;
  esac
done
exit $fail
