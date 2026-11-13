# VoiceType: free, private, offline voice typing for Android and Mac

## What is this?

VoiceType lets you **talk instead of type** in any app. Press a key or tap a mic and speak. It
turns your speech into clean, punctuated text: filler words removed, self-corrections applied
("at 5, no wait, 6" → "at 6"), with optional AI polish. The text goes straight into whatever you're
typing in.

It's a **free, self-hosted alternative to paid dictation subscriptions like Wispr Flow** and
similar AI voice-typing tools. Those typically process your audio on their cloud servers and charge a
monthly fee. VoiceType runs **entirely on your own device**:

| | Typical paid cloud dictation apps | VoiceType |
|---|---|---|
| Cost | Monthly subscription | Free; you build it yourself |
| Where your voice goes | Usually processed on their servers | Never leaves your phone / Mac |
| Internet needed | Yes | No; works in airplane mode |
| Account / sign-in | Required | None |
| Privacy guarantee | Their privacy policy | Enforced by the OS: the apps have **no network permission at all** |
| Languages | Varies | English, Hindi, Hinglish (Latin or Devanagari) |

Speech recognition uses open-source models (Moonshine and Whisper via sherpa-onnx). The optional
AI polish uses a small on-device LLM (Gemma via LiteRT-LM on Android, Apple Intelligence's
on-device model on Mac).

## Download

Ready-made builds are on the [**Releases page**](https://github.com/CurlyRishabh/VoiceType/releases/latest).
These links always point to the newest version:

| | Download | Then |
|---|---|---|
| **Android** (12+, arm64) | [**VoiceType.apk**](https://github.com/CurlyRishabh/VoiceType/releases/latest/download/VoiceType.apk) (~58 MB) | Open it on the phone and allow "Install unknown apps", or `adb install VoiceType.apk`. Then follow §5. |
| **macOS** (15+) | [**VoiceType.dmg**](https://github.com/CurlyRishabh/VoiceType/releases/latest/download/VoiceType.dmg) (~11 MB) | Open the DMG and drag VoiceType to Applications. See [`mac/README.md`](mac/README.md). |
| **Speech models** (both apps) | [**VoiceTypeModels.zip**](https://github.com/CurlyRishabh/VoiceType/releases/latest/download/VoiceTypeModels.zip) (~660 MB) | Unzip, then import the folders in the app (§4). Contains Silero VAD, Moonshine (English) and Whisper small (Hindi + English). |

The apps aren't from an app store, so you'll see an expected warning the first time:

* **Mac:** the app is ad-hoc signed, not notarized. If macOS says it can't verify the developer, go
  to **System Settings → Privacy & Security → Open Anyway**, or right-click the app → **Open**.
* **Android:** sideloaded APKs land behind Android 13+'s "restricted settings" for Accessibility.
  See step 6 in §5 for how to allow it.

You can also build both apps yourself from source (below) instead of downloading them.

## What's in this repo

| App | What you get | How to build it | Docs |
|---|---|---|---|
| **Android** (`.apk`) | Voice keyboard + floating mic bubble that types into any app | `./gradlew assembleRelease` → `app/build/outputs/apk/release/app-release.apk` | This file, §1–§10 below |
| **macOS** (`.dmg`) | Menu-bar app: press **⌥ Space**, speak, and the text is pasted into the focused app | `mac/scripts/build-dmg.sh` → `mac/build/VoiceType.dmg` | [`mac/README.md`](mac/README.md) |

The built `.apk` / `.dmg` files and the speech models aren't committed to git (they're large).
Download them from the [Releases page](#download), or build the apps from source and fetch the
models yourself (§4).

**Requirements:** Android 12+ on an arm64 phone (built and tuned for a OnePlus 10R), or macOS 15+
(Apple silicon recommended; AI polish on Mac needs macOS 26 with Apple Intelligence).

### Quick start

1. **Get the models:** download [`VoiceTypeModels.zip`](#download) and unzip it, or fetch them
   yourself (§4): Silero VAD + Moonshine (English) and/or Whisper (Hindi + English).
2. **Android:** [download the APK](#download) (or build it, §2), install it (§3), copy the models
   to the phone and import them, then follow the setup wizard (§5).
3. **Mac:** [download the DMG](#download) (or run `mac/scripts/build-dmg.sh`), open it, drag
   VoiceType to Applications, then import the models folder from the Setup tab.
4. Start talking: tap the mic (Android) or press ⌥ Space (Mac).

---

# Android app

Built for a personal phone (**OnePlus 10R**, Dimensity 8100, 8–12 GB RAM, OxygenOS, Android 12+).
Everything runs on the phone: speech recognition, clean-up, and the optional AI polish. **The app
has no internet permission**, so nothing you say can leave the device.

* **Voice keyboard**: big mic (tap = auto-stop on silence, hold = push-to-talk), live level meter,
  backspace, space, enter, switch-keyboard.
* **Floating mic bubble**: drag it anywhere; tap or hold to dictate into whatever text field has focus.
* **System speech recogniser**: other keyboards/apps that use Android's `SpeechRecognizer` can use it.
* **Two engines**: *Fast English* (Moonshine Base int8) and *Hindi + English* (Whisper small int8,
  Hindi / English / auto-detect, Hinglish, Latin or Devanagari output).
* **Clean-up**: filler removal, self-corrections ("5 no wait 6"), spoken commands, capitalisation,
  personal dictionary, then optional on-device LLM polish (Casual / Professional / Notes) with a hard
  3 s timeout.

---

## 1. Project layout

```
voiceapk/
├── app/          UI (setup wizard, settings, models, dictionary, history, debug), IME,
│                 RecognitionService, floating bubble service, boot receiver, privacy build gate
├── engine/       AudioRecord capture, Silero VAD auto-stop, sherpa-onnx Moonshine/Whisper,
│                 warm model host (load/decode/release on one thread), RTF logging
├── cleanup/      PURE KOTLIN (JVM) – Stage 1 rules, Devanagari→Latin transliteration,
│                 Stage 2 prompt/guard/timeout pipeline. 140+ unit tests.
├── polish/       LiteRT-LM on-device LLM (implements cleanup's Polisher interface)
├── insertion/    AccessibilityService + safe text insertion (SET_TEXT or clipboard paste)
├── third_party/maven/   local Maven repo for the sherpa-onnx AAR (GitHub-only release)
└── scripts/fetch-sherpa-aar.sh   downloads + SHA-256-verifies that AAR
```

Kotlin + classic Views (no Compose) · minSdk 31 · targetSdk/compileSdk 37 · arm64-v8a only ·
R8 + resource shrinking in release · AGP 9.5.1 · Kotlin 2.4.21 · Gradle 9.9.1 ·
sherpa-onnx 2.0.1 · LiteRT-LM 0.19.1.

---

## 2. Build

Requirements: a recent **Android Studio** (it bundles JDK 21) with **Android SDK Platform 37**
installed (Studio offers to install it on first sync).

```bash
cd voiceapk
./scripts/fetch-sherpa-aar.sh          # once: downloads sherpa-onnx-2.0.1.aar and checks its SHA-256
./gradlew test                          # all unit tests (cleanup rules, chunking, model detection…)
./gradlew assembleRelease               # → app/build/outputs/apk/release/app-release.apk (~58 MB)
```

Or open the folder in Android Studio and press **Run**. The release build is signed with your local
debug key, which is fine for a personal sideloaded app.

Every `assemble*`/`install*` build runs `verify<Variant>Privacy`, which **fails the build** if the
merged manifest (including all libraries) asks for any network permission, if `allowBackup` isn't
`false`, or if Firebase / Play Services / crash-reporter libraries appear on the runtime classpath.

## 3. Install on the OnePlus 10R

1. On the phone: **Settings → About device → Version → tap "Build number" 7 times**, then
   **Settings → Additional settings → Developer options → USB debugging: on**.
2. Connect USB, accept the "Allow USB debugging?" prompt.
3. ```bash
   adb install -r app/build/outputs/apk/release/app-release.apk
   ```
   (or Run from Android Studio).

Installing via `adb`/Android Studio also avoids Android 13+'s "restricted settings" block on the
Accessibility toggle (see §5 if you sideload the APK some other way).

---

## 4. Models: download on your computer, copy to the phone, import once

The app cannot download anything, so you fetch the models on a computer. All links below are the
official sherpa-onnx / LiteRT community uploads. Download **just the listed files** (no archives to
extract).

### Required

| Model | Files (download each) | Size |
|---|---|---|
| **Silero VAD** (auto-stop) | [`silero_vad.onnx`](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx) | 0.6 MB |
| **Fast English**: Moonshine Base int8 | from `https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-base-en-int8/resolve/main/` → `preprocess.onnx`, `encode.int8.onnx`, `uncached_decode.int8.onnx`, `cached_decode.int8.onnx`, `tokens.txt` | 287 MB |
| **Hindi + English**: Whisper small int8 | from `https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/` → `small-encoder.int8.onnx`, `small-decoder.int8.onnx`, `small-tokens.txt` | 375 MB |

You need the VAD plus at least one speech model; get both for English and Hindi/Hinglish.
(Newer alternative for Fast English: `sherpa-onnx-moonshine-base-en-quantized-2026-02-27` with
`encoder_model.ort`, `decoder_model_merged.ort`, `tokens.txt` also works.)

### Optional: AI polish model (`.litertlm`)

| Model | File | Size | Notes |
|---|---|---|---|
| **Gemma 3 1B IT int4** (recommended) | [`gemma3-1b-it-int4.litertlm`](https://huggingface.co/litert-community/Gemma3-1B-IT/blob/main/gemma3-1b-it-int4.litertlm) | 584 MB | Fastest; good with Hindi/Hinglish. Gated: sign in to Hugging Face and accept the Gemma licence first. |
| Qwen2.5 1.5B Instruct q8 | [`Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm`](https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/blob/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm) | 1.6 GB | No login needed. Bigger/slower: long dictations will hit the 3 s limit more often. |

Avoid "thinking" models (e.g. Qwen3): they spend the 3 s budget reasoning.

Example (macOS/Linux):

```bash
mkdir -p ~/VoiceTypeModels/{vad,moonshine,whisper,llm} && cd ~/VoiceTypeModels
curl -L -o vad/silero_vad.onnx https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
M=https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-base-en-int8/resolve/main
for f in preprocess.onnx encode.int8.onnx uncached_decode.int8.onnx cached_decode.int8.onnx tokens.txt; do curl -L -o moonshine/$f $M/$f; done
W=https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main
for f in small-encoder.int8.onnx small-decoder.int8.onnx small-tokens.txt; do curl -L -o whisper/$f $W/$f; done
# Polish model: download in the browser (Gemma needs login), save into ~/VoiceTypeModels/llm/
```

### Copy to the phone

Either drag the `VoiceTypeModels` folder onto the phone's **Download** folder in a USB file-transfer
window, or:

```bash
adb push ~/VoiceTypeModels /sdcard/Download/VoiceTypeModels
```

### Import in the app

Open **VoiceType → Import models** (or Settings → Models). For each model tap **Import** and, in the
system file picker, open `Download/VoiceTypeModels/<folder>` and **select all of that model's
files at once** (long-press the first file, then tap the others). The app copies them into
private, non-backed-up storage and shows **Ready**. Afterwards you can delete the copies in
`Download`. From then on everything works in airplane mode.

---

## 5. Set up on the phone

Launch **VoiceType**. The setup wizard shows a live ✓ / to-do status for each step:

1. **Microphone** (+ notifications for the bubble's status notification).
2. **Import models** (above).
3. **Enable the VoiceType keyboard**: Android shows its generic "this keyboard may collect text"
   warning; VoiceType has no network access.
4. **Switch to it**: tap *Choose keyboard*, or keep your usual keyboard and use the bubble.
5. **Display over other apps** (for the bubble).
6. **Bubble typing permission (Accessibility)**: an explainer screen first says exactly what the
   service does and doesn't do. In Accessibility choose *Installed/Downloaded apps → VoiceType bubble
   typing → On*. If the switch is greyed out (Android 13+ "restricted setting"): **Settings → Apps →
   VoiceType → ⋮ (top right) → Allow restricted settings**, then try again.
7. **Battery → Unrestricted**: *Allow* shows the system dialog. On OxygenOS also check
   **App info → Battery usage → Unrestricted / Allow background activity**.
8. **Auto-launch (OnePlus)**: *Open* tries OxygenOS's auto-launch screen; otherwise
   **App info → Battery usage → Allow auto launch** (OxygenOS 13+) or
   **Settings → Apps → Auto launch**. Also lock VoiceType in Recents (Recents → app's ⋮ → Lock).
9. **Show floating mic bubble** switch.
10. **Try it** in the test box.

Optional: to make VoiceType the system speech recogniser for other apps, pick it under
**Settings → Apps → Default apps → Digital assistant / Voice input** (wording varies by OxygenOS
version).

## 6. Using it

* **Keyboard**: tap the mic and talk; it stops after 1.5 s of silence (Settings → *Auto-stop after
  silence*). Hold the mic for push-to-talk. ⌨ switches back to your previous keyboard (long-press: picker).
* **Bubble**: tap to start/stop or *hold to talk* (Settings → Bubble mode); drag to move. Red =
  listening, orange = transcribing/polishing. If no field is focused or the app refuses input, the
  text is copied to the clipboard instead.
* **Spoken commands**: "new line", "new paragraph", "comma", "full stop" / "period" (at the end),
  "question mark", "exclamation mark"; Hinglish "nayi line".
* **Corrections**: "at 5 no wait 6", "Monday I mean Tuesday", "kal nahi nahi parson" keep only the fix.
* **Fillers removed**: um/uh/er/hmm, standalone "like" / "you know", "matlab" and "haan toh" when
  used as fillers.
* **Hindi**: Settings → Language = Hindi or Auto-detect; *Hindi output script* = Latin (Hinglish,
  e.g. "kal meeting hai") or Devanagari.
* **AI polish**: Settings → AI polish, Style = Casual / Professional / Notes.
* **Personal dictionary**: e.g. `acme → Acme`; always applied last (even after AI polish).
* **History**: stored only on the phone; tap to copy, long-press to delete, *Clear all* wipes it
  immediately. Can be turned off.

---

## 7. Prove it's private

1. **The build refuses network permissions.** Run `./gradlew :app:verifyReleasePrivacy`. It prints
   the merged-manifest permissions and fails if any of `INTERNET`, `ACCESS_NETWORK_STATE`,
   `ACCESS_WIFI_STATE`, `CHANGE_NETWORK_STATE`, `CHANGE_WIFI_STATE`, `NEARBY_WIFI_DEVICES` appear,
   or if `allowBackup` isn't `false`. The app manifest also strips these with `tools:node="remove"`.
   You can inspect the merged manifest yourself at
   `app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml`
   (or Android Studio → `AndroidManifest.xml` → *Merged Manifest* tab).
2. **Check the APK itself:**
   ```bash
   $ANDROID_HOME/build-tools/37.0.0/aapt2 dump permissions app/build/outputs/apk/release/app-release.apk
   ```
   Expected: `RECORD_AUDIO`, `POST_NOTIFICATIONS`, `SYSTEM_ALERT_WINDOW`, `FOREGROUND_SERVICE*`,
   `RECEIVE_BOOT_COMPLETED`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and androidx's internal
   `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. **No `INTERNET`.**
3. **Check what the phone granted:**
   ```bash
   adb shell dumpsys package dev.offline.voicetype | grep -i -E "permission|INTERNET"
   ```
   Without `android.permission.INTERNET`, Android's kernel-level network filter blocks every socket
   the app (or any library in it) tries to open.
4. **Airplane-mode test:** turn on airplane mode (Wi-Fi and Bluetooth off too), then dictate with the
   keyboard and the bubble, with and without AI polish. Everything works.
5. **No backups:** `allowBackup="false"` plus `dataExtractionRules` excluding everything from cloud
   backup *and* device-to-device transfer. Models live in `noBackupFilesDir`.
6. **No trackers:** the build fails if Firebase, Play Services, Crashlytics or Sentry appear on
   the runtime classpath, and `dependenciesInfo` is off so no dependency metadata blob ships in the APK.
7. **Audio:** held in memory only, zeroed after transcription. The *Keep recordings* debug toggle
   (off by default) is the only thing that writes WAVs, to app-private storage; *Debug → Delete kept
   recordings* removes them.

## 8. Debug & benchmark

Settings → **Debug & benchmark** shows, for recent dictations, audio length, decode time and
**real-time factor** (decode ÷ audio; below 1 is faster than real time), model load times, polish
time and any polish fallback reason (timeout, rejected output, model not loaded). **Record 5 s and
benchmark** runs every imported engine on the same clip. Logs: `adb logcat -s SpeechEngineHost LiteRtPolisher Dictation`.

## 9. How it works (short)

* `DictationRecorder` reads 512-sample frames from `AudioRecord` (16 kHz mono PCM16,
  `VOICE_RECOGNITION`), feeds Silero VAD, and stops after `silence` ms of trailing silence (or 8 s
  with no speech, or 5 min).
* VAD segments are merged into ≤25 s chunks (Whisper's window is 30 s), silence between them is
  skipped, and chunks are decoded in order by `SpeechEngineHost` (4 threads). That host does load,
  decode and release on **one** thread, so memory-pressure or idle release can never free a
  model mid-decode. Models are released after 5 idle minutes, or on `onTrimMemory(UI_HIDDEN+)`
  when no keyboard/bubble is active.
* `CleanupPipeline` (pure Kotlin): optional Devanagari→Latin → Stage 1 rules → Stage 2 LLM on a
  worker thread with a 3 s `Future.get` timeout (then `cancelProcess()`), and a `PolishGuard` that
  rejects translated, answered, invented or truncated output. The dictionary is re-applied after
  the LLM.
* `TextInserter` uses `ACTION_SET_TEXT` (existing text + dictation spliced in at the cursor, then
  `ACTION_SET_SELECTION`) only where that's safe; for password fields, browsers/WebViews, very long
  fields or unknown cursors it pastes via the clipboard (clip marked *sensitive*), then restores the
  previous clip.

## 10. Known limitations

* **Not yet run on a real phone.** The project compiles (debug + release with R8), lint shows no
  errors, and all unit tests pass, but on-device behaviour (OxygenOS background limits, mic access
  after reboot, accessibility insertion in specific apps) still needs testing on the 10R.
* **Clipboard restore:** Android 10+ only lets the focused app or the default keyboard *read* the
  clipboard. When the bubble's paste fallback can't read your previous clip, it clears the clipboard
  after pasting instead of leaving your dictation on it. The `SET_TEXT` path doesn't touch the clipboard.
* **Bubble after reboot:** Android won't give a background-started service microphone access.
  The first bubble tap after a reboot briefly opens an invisible activity to obtain it.
* **Hinglish in Latin script** is Whisper's Devanagari output transliterated with Hindi
  schwa-deletion rules ("करना" → "karna"). English loanwords come out phonetic ("meeting" is fine,
  some aren't); AI polish is told to fix English spellings in Hinglish.
* **"period"** is only treated as a command at the end of a line and not after words like
  "the/a/trial/grace"; say "full stop" mid-sentence.
* **Hindi on Whisper small:** sherpa-onnx's Whisper decoder allows only 6 output tokens per
  second of audio, which cut Hindi sentences off halfway. Hindi/auto chunks are kept ≤ 8 s and
  padded with silence so the whole sentence fits. This costs extra encoder time for Hindi only.
  Whisper small's Hindi accuracy is still modest; large-v3-turbo is much better but too heavy for the phone.
* **Polish latency:** the 3 s limit is strict by design. The debug screen shows how often it
  falls back. Gemma 3 1B int4 is the best fit; try *Use GPU* if CPU is too slow.

---

## License

VoiceType's own code is released under the [MIT License](LICENSE).

The speech models and libraries it uses are downloaded separately and keep their own licenses:
sherpa-onnx, LiteRT-LM and AndroidX (Apache-2.0); Moonshine, Whisper and Silero VAD (MIT);
Qwen2.5 (Apache-2.0); Gemma (the [Gemma Terms of Use](https://ai.google.dev/gemma/terms)). Wispr Flow
is a trademark of its owner; VoiceType isn't affiliated with it.
