# VoiceType for Mac: private, offline dictation

A menu-bar app that types what you say into any app. It runs entirely on your Mac: speech
recognition (Whisper large-v3-turbo via whisper.cpp on the GPU by default; Moonshine via sherpa-onnx
optional), the clean-up rules (the same rules and tests as
the Android app), and optional AI polish with Apple's **on-device** model. The app is
**sandboxed with no network entitlement**, so macOS itself blocks it from connecting anywhere.

## Install

Needs an Apple-silicon Mac (M1 or newer) on macOS 15+.

1. **Install:** `brew install --cask curlyrishabh/tap/voicetype` (installs the speech model as well),
   or open `VoiceType.dmg` and drag **VoiceType** into **Applications**.
2. **Open it** from Applications. It lives in the menu bar (🎙 icon), with no Dock icon.
   This is an ad-hoc-signed build: the first time, macOS says it can't verify the developer. Go to
   **System Settings → Privacy & Security → Open Anyway**.
3. **The Setup window** walks you through the rest:
   * **Languages**: tick the ones you dictate in: English, हिंदी (Hindi), or both for Hinglish.
     With Hindi you also pick Latin ("kal meeting hai") or Devanagari ("कल मीटिंग है") output, or
     turn on **Translate to English** (Settings, or the menu bar) to have Hindi and Hinglish typed
     as English ("there is a meeting tomorrow"). English is always typed as English.
   * **Microphone**: click *Allow microphone* and choose **Allow** in the macOS dialog.
   * **Accessibility (auto-paste)** and **Input Monitoring** (for the fn key): click *Allow*. macOS
     adds VoiceType to the list in Privacy & Security and offers to open it; just **switch VoiceType
     on**, there's no need to add it with +. Also set "Press 🌐 key to" to **Do Nothing** (or pick
     ⌥ Space, which needs no Input Monitoring). If macOS asks to *Quit & Reopen* VoiceType, do;
     setup carries on where it was.
   * **Speech model**: already done if you installed with Homebrew. Otherwise click **Download**
     (your browser downloads one 548 MB file), then **Import…** and choose
     `ggml-large-v3-turbo-q5_0.bin` in Downloads. VoiceType checks its size and SHA-256, copies it
     into its models folder, and you can delete the download.

That's the only download: the voice-activity model ships inside the app, and Whisper is the default
engine for English and Hindi. The model lives in **`~/Library/Application Support/VoiceType/Models`**,
the same folder whether Homebrew or Import put it there, so updating VoiceType never downloads or
imports it again. (Models imported by version 1.0 are moved there on first launch.)

> Rebuilt the app? macOS ties permissions to the exact build for ad-hoc-signed apps. If dictation
> stops pasting after an update, remove VoiceType from Privacy & Security → Accessibility and add it again.

## Use

| Do this | What happens |
|---|---|
| **Hold fn** and talk | Records while you hold, through pauses. Release and the text is typed. |
| **Double-tap fn** | Hands-free: keeps listening until you **tap fn** again (or click ■ on the flow bar). A double-tap can be as slow as your double-click speed (System Settings → Mouse/Trackpad). |
| **⇧⌥ Space** | Also hands-free: press once to start, again to finish. Needs no permission. Pressed while holding fn, it keeps the recording going after you let go. Turn it off in Settings → Dictation. |
| **esc** (or ✕) | Cancels; nothing is typed. |
| **fn + another key** | Works as normal (fn+arrows, F-keys); dictation ignores it. |
| **⌃⌥R** | Starts or stops a [meeting recording](#meeting-transcription). Needs no permission. Turn it off in Settings → Meetings. |

* The **flow bar** at the bottom of the screen appears only while you dictate: level bars while you
  talk, a timer with ✕ and ■ in hands-free mode, "Typing…", or a one-line notice with a **Fix**
  button. (Want a small sliver there when idle too? Settings → Advanced → *Show the flow bar when idle*.)
* The **VoiceType window** (menu bar → *Open VoiceType…*) has tabs for **History** (search and
  re-copy what you said), **Meetings** (see [Meeting transcription](#meeting-transcription)),
  **Dictionary** and **Styles**. The gear button opens **Settings**.
* Long hands-free dictations are transcribed sentence by sentence while you talk, so the text is
  ready almost as soon as you stop (limit: 15 minutes; holding: 5 minutes).
* **Styles** pick the AI-polish tone from the app you're typing in: Messages/Slack/WhatsApp →
  Casual, Mail/Outlook → Formal, Notes/Obsidian/Notion → bullet Notes, everything else → instant
  rules only. Change any of them in VoiceType → Styles.
* The **menu bar** icon has the last dictation (**Paste again** / Copy), the language switch,
  "Start hands-free", and "Pause fn for 1 hour".
* No fn key (most external keyboards)? Settings → Dictation key → **Right ⌥**, or **⌥ Space**
  (⌥ Space needs no Input Monitoring permission).

**One-time setup for fn:** System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**
(otherwise macOS also opens the emoji picker on every press), and allow VoiceType under
Privacy & Security → **Input Monitoring**. It uses a listen-only key tap: it can't block or change
keys and only reacts to fn and esc.

Same clean-up as on the phone: filler removal, self-corrections ("at 5 no wait 6"), spoken
commands ("new line", "comma", "question mark"…), personal dictionary, Hindi / Hinglish with Latin
or Devanagari output, local-only history.

## Meeting transcription

VoiceType can also record a meeting (Zoom, Meet, Teams, Slack huddles: any app) and transcribe it
on the Mac, with no bot joining the call and nothing uploaded. It is a transcript only: paste it
into Claude or Codex for a summary (**Copy for AI** adds the instructions).

**Start / stop:** **⌃⌥R** from any app, the menu bar (*Start meeting recording*), or the
**Meetings** tab's *Start recording*. While it records, the flow bar shows a pulsing red dot, the
time, a two-tone level meter (white = you, teal = the others) and a ■ button; hover it for the
title and word count. Dictation keeps working during a meeting; the bar returns to the meeting
afterwards.

**How it works**

* **Two channels, two speakers.** Your microphone is **Me**; the sound of every other app (a Core
  Audio process tap on all output except VoiceType's own) is **Others**. No speaker recognition
  beyond that.
* **Written to disk as it records.** Each channel goes to `mic.wav` / `system.wav` (16 kHz, 16-bit)
  in the meeting's folder, aligned on one clock, so a crash, quit or sleep loses nothing. If the
  app quits or crashes mid-meeting, the next launch transcribes what was recorded.
* **Transcribed while you talk.** Each channel has its own voice detector; finished stretches of
  speech (up to 25 s) are decoded in the background, one at a time, so a dictation never waits for
  more than one of them. After *Stop* only the last few seconds are left ("Wrapping up…"):
  measured on an M5 Pro, a 10.8-minute two-channel test meeting decoded at **RTF 0.024**
  (English) / **0.045** ("Both": the language is picked per chunk), and fed at 10× real time the
  transcript was ready **0.4 s** after Stop. Roughly 1.5–3 minutes of GPU time per meeting hour,
  spread over the meeting.
* **Same model and settings as dictation:** Whisper large-v3-turbo on the GPU, your language
  setting (English / हिंदी / Both; Hindi in Latin or Devanagari as you chose), and your Dictionary
  as the vocabulary hint and spellings. *Translate to English* doesn't apply to meetings. The
  model stays loaded while a meeting records.
* **Meeting-safe clean-up.** None of dictation's rewriting: "comma" or "new line" stay words, "no
  wait" isn't a correction, nothing is removed as a filler. Only capitals, Hindi script and the
  Dictionary. Whisper's near-silence inventions ("Thank you.") are dropped per chunk, as is a chunk
  that only repeats the one before (hold music, noise), and near-silent chunks aren't decoded.
* **Echo without headphones.** The mic also hears the others through the speakers; a Me line that
  closely matches what the others said at the same moment is dropped (Settings → Meetings →
  *Remove echo when not using headphones*; turn it off if your own lines go missing). Headphones
  avoid the problem entirely.

**Files.** One folder per meeting:
`~/Library/Application Support/VoiceType/Meetings/<YYYY-MM-DD HHmm> <title>/`

| File | What |
|---|---|
| `transcript.md` | Title, date, time, length, model, languages; a short instruction block for Claude/Codex (summary, decisions, action items with owners, open questions, cite timestamps); then `[hh:mm:ss] **Me:** …` / `**Others:** …` lines, consecutive lines of one speaker merged |
| `transcript.json` | Every segment: `start`, `end` (seconds), `channel`, `speaker`, `text`, `language` |
| `meeting.json` | Title, start/end, status, length, decode time, real-time factor, stop reason, system-audio state, word count |
| `mic.wav`, `system.wav` | The audio, while recording. Deleted once the transcript is saved unless **Keep audio after transcription** is on (about 115 MB per channel per hour) |

**The Meetings tab** lists them (title, date, length, words, Recording / Transcribing / Ready /
Failed, search over titles and transcripts). A meeting opens with an editable title, the
transcript with timestamps and speakers, find (with next/previous), **Copy transcript**, **Copy
for AI**, **Show in Finder** and **Delete**.

**Permissions.** The microphone, as for dictation, plus **System Audio Recording** for the other
side: macOS asks the first time you record a meeting (Privacy & Security → *Screen & System Audio
Recording* → "System Audio Recording Only"). There is no way for an app to check this permission:
when it is off, the other apps' sound is simply silent. VoiceType notices that after a few seconds
and shows **"Recording your mic only"** with a *Turn on* button (it can also mean nothing has played
yet). The first recording also reminds you to tell the others they are being recorded; in many
places and companies that is required.

**Guards.** A maximum length (30 min / 1 h / **2 h** / 3 h, Settings → Meetings), with a warning 5
minutes before and an automatic stop and save; stop and save when the Mac goes to sleep; a warning
when the disk has under an hour of recording left, and a stop when it is nearly full; a
"Started by mistake?" *Discard* offer when fewer than 20 words were transcribed. The flow bar and
VoiceType's windows are hidden from screen sharing and screen recordings while a meeting records
(on by default).

**Privacy.** Same as dictation: no network entitlement, so macOS blocks VoiceType from connecting
anywhere; audio and transcripts stay in the folder above. The entitlements are unchanged: the
meetings folder is inside the one home-folder path VoiceType could already write.

**Limits.** Only Me vs Others (several people on the call are all "Others"). No pause/resume: a
stopped meeting is finished. No live transcript view while recording (it is written in the
background and shown after Stop). The echo filter is deliberately conservative. Meetings need the
Whisper model (with only Moonshine imported, English meetings work with chunk-level times).

Test the pipeline without a real call (two macOS voices, a Hindi line, echo in the mic channel):
```bash
scripts/test-meeting.sh        # pass/fail checks + timing; MODELS=/path to use another models folder
DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib VOICETYPE_VAD=vendor/silero_vad.onnx \
  "$(swift build -c release --arch arm64 --show-bin-path)/VoiceType" --meeting mic.wav system.wav ../models auto
```
How it is put together: [`MEETING_DESIGN.md`](MEETING_DESIGN.md). What still needs a real Mac
with permissions: [`MEETING_TEST_PLAN.md`](MEETING_TEST_PLAN.md).

## Models

The same files as the phone (`voiceapk/models`):

| Folder | Files | Notes |
|---|---|---|
| `vad/` | `silero_vad.onnx` | required (auto-stop) |
| `moonshine/` | `preprocess.onnx`, `encode.int8.onnx`, `uncached_decode.int8.onnx`, `cached_decode.int8.onnx`, `tokens.txt` | Fast English (RTF ≈ 0.01 on Apple silicon) |
| `whisper/` | `small-encoder.int8.onnx`, `small-decoder.int8.onnx`, `small-tokens.txt` | Hindi + English |

**Default: whisper.cpp on the GPU.** The Setup's **Download** button fetches
**`ggml-large-v3-turbo-q5_0.bin`** (548 MB) from this project's
[`models-v1` release](https://github.com/CurlyRishabh/VoiceType/releases/tag/models-v1), the file
Homebrew's `voicetype-model` cask installs too
(SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`, checked on import).
Any other whisper.cpp `ggml-*.bin` can be imported the same way; the newest import replaces the old
one. Older setups keep working: the sherpa-onnx Whisper ONNX files and Moonshine can still be
imported as a folder (with `vad/`, `moonshine/`, `whisper/` inside), and if only Moonshine is
present, English falls back to it.

Measured on an M5 Pro (synthetic speech, after the first load):

| Engine | Hindi sentence (5.7 s) | English sentence (7.3 s) |
|---|---|---|
| sherpa-onnx Whisper small (CPU) | 2.1 s, many wrong words | 0.6 s |
| **whisper.cpp large-v3-turbo q5_0 (GPU)** | **0.3 s, nearly exact** | **0.2 s** |
| Moonshine Base (CPU, Fast English) | n/a | 0.08 s |

The first dictation after launch takes ~3 s longer while Metal compiles its kernels.

**Your Dictionary helps recognition too.** With whisper.cpp, the spellings on the right-hand side of
your Dictionary (e.g. `Cassie QC agent`, `ChargeBee`) are given to Whisper as a vocabulary prompt,
so it hears them correctly instead of "CASI QC agent" or "charge B". This applies to the Hindi +
English engine (choose it as the English engine in Settings to use it for English too). Moonshine
and the sherpa-onnx Whisper can't take a prompt; the Dictionary still fixes their output afterwards.

**AI polish** uses Apple Intelligence's on-device model (macOS 26+, Apple silicon, Apple
Intelligence turned on in System Settings). There's nothing to download. The app uses only
`SystemLanguageModel.default` (on-device), never Apple's Private Cloud Compute, and the sandbox has no
network entitlement anyway. If the model isn't available, the instant rules are used.

## Prove it's private

```bash
codesign -d --entitlements - /Applications/VoiceType.app
```
You'll see `com.apple.security.app-sandbox = true`, `device.audio-input`,
`files.user-selected.read-only`, one `temporary-exception.files.home-relative-path.read-write` for
`/Library/Application Support/VoiceType/` (the models folder, nothing else in your home folder), and
**no** `com.apple.security.network.client` or `network.server`.
A sandboxed app without those can't open network connections; the kernel refuses them. You can
also turn Wi-Fi off and dictate normally, or watch `nettop -p VoiceType` (it never shows a
connection). Settings and history live only in `~/Library/Containers/dev.offline.voicetype.mac/`,
models in `~/Library/Application Support/VoiceType/Models`; both are excluded from Time Machine.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```bash
cd mac
scripts/build-dmg.sh      # fetches sherpa-onnx + whisper.cpp (checksum-verified), runs unit tests, builds,
                          # signs ad-hoc with the sandbox entitlements, verifies them, makes the DMG
open build/VoiceType.dmg
```

Test the speech stack on real audio (any wav, m4a, mp3 or flac; uses the app's models folder,
or `MODELS=/path`):
```bash
scripts/test-audio.sh                    # built-in pass/fail checks on clips spoken by macOS voices
scripts/test-audio.sh clip.m4a other.wav # what each clip types in every language / translate mode
```
With "Keep recordings" on, the app saves every dictation to
`~/Library/Containers/dev.offline.voicetype.mac/Data/Library/Application Support/VoiceType/recordings`,
so a dictation that came out wrong can be replayed with `scripts/test-audio.sh` directly.

One clip, one mode (unsandboxed dev binary):
```bash
DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib "$(swift build -c release --arch arm64 --show-bin-path)/VoiceType" \
  --selftest ../models some.wav hi whisper            # add --translate and/or --devanagari
# test the vocabulary prompt (whisper.cpp only):
VOICETYPE_PROMPT="Cassie QC agent, ChargeBee" DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib ... --selftest ../models some.wav en whisper
```
The models folder must contain real folders (not symlinks).

## Benchmark on real audio

`scripts/bench-asr.sh` measures accuracy and speed of each engine on real recordings, using the same
voice detection, chunking and filtering as live dictation:

```bash
cd mac
scripts/bench-asr.sh                     # 100 clips each of LibriSpeech clean/other + FLEURS Hindi
scripts/bench-asr.sh --n 300 --sets hindi
scripts/bench-asr.sh --cv ~/Downloads/cv-corpus-21.0/hi --cv-lang hi --sets cv   # Common Voice
VOICETYPE_PROMPT="Cassie QC agent, ChargeBee" scripts/bench-asr.sh --sets clean  # with a vocabulary prompt
```

| Dataset | What it tests | Download |
|---|---|---|
| LibriSpeech test-clean | English, clear audiobook speech | automatic (347 MB, MD5-checked) |
| LibriSpeech test-other | English, harder speakers and recordings | automatic (329 MB, MD5-checked) |
| FLEURS hi_in test | Real Hindi speech | automatic (249 MB, SHA-256-checked, CC-BY-4.0) |
| Common Voice | Accents, everyday speech | manual: Mozilla now requires a free account at <https://datacollective.mozillafoundation.org>; extract a language and pass its folder with `--cv` |

It benchmarks every engine whose model it finds in `--models` (default `../models`):
whisper.cpp (`whisper-cpp/*.bin` or `whisper/*.bin`), Moonshine, and sherpa-onnx Whisper. The report
is `bench-data/results/summary.md`, with one TSV per dataset and engine listing every clip's reference
and hypothesis. **WER** = word error rate, **CER** = character error rate (fairer for Hindi), lower
is better. **RTF** = decode time / audio length. The text normaliser is deliberately simple
(lower-case, no punctuation, digits spelled out), so absolute WERs run a little above published
figures; compare engines with each other. Downloads and results live in `bench-data/` (git-ignored).

## Notes

* **Hindi fix (also applied to the Android app):** sherpa-onnx's Whisper decoder allows only 6
  output tokens per second of audio, which cut Hindi sentences off halfway. Hindi/auto chunks are
  now kept ≤ 8 s and padded with silence so the full sentence fits. whisper.cpp has no such cap, so
  with a `ggml-*.bin` model the chunks are plain ≤ 25 s and unpadded.
* **whisper.cpp** is the prebuilt `whisper.xcframework` from the official release (build b5454 =
  v1.9.5), pinned by SHA-256 in `scripts/fetch-whisper-cpp.sh`. Only its Apple-silicon slice is
  bundled. It runs inside the same sandbox with no network entitlement.
* The hot key uses Carbon `RegisterEventHotKey` (no Input Monitoring permission needed). ⌥ Space
  normally types a non-breaking space; pick another shortcut if you need that.
* Clipboard: the pasted text is marked *transient/concealed* so clipboard managers ignore it, and your
  previous clipboard is restored half a second later.
