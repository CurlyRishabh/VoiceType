# VoiceType for Mac: private, offline dictation

A menu-bar app that types what you say into any app. It runs entirely on your Mac: speech
recognition (Whisper large-v3-turbo via whisper.cpp on the GPU by default; Moonshine via sherpa-onnx
optional), the clean-up rules (the same rules and tests as
the Android app), and optional AI polish with Apple's **on-device** model. The app is
**sandboxed with no network entitlement**, so macOS itself blocks it from connecting anywhere.

## Install

Needs an Apple-silicon Mac (M1 or newer) on macOS 15+.

1. **Install:** `brew install --cask curlyrishabh/tap/voicetype`, or open `VoiceType.dmg` and drag
   **VoiceType** into **Applications**.
2. **Open it** from Applications. It lives in the menu bar (🎙 icon), with no Dock icon.
   This is an ad-hoc-signed build: the first time, macOS says it can't verify the developer. Go to
   **System Settings → Privacy & Security → Open Anyway**.
3. **The Setup window** walks you through the rest:
   * **Languages**: tick the ones you dictate in: English, हिंदी (Hindi), or both for Hinglish.
     With Hindi you also pick Latin ("kal meeting hai") or Devanagari ("कल मीटिंग है") output.
   * **Microphone**: click *Allow microphone* and choose **Allow** in the macOS dialog.
   * **Accessibility (auto-paste)** and **Input Monitoring** (for the fn key): click *Allow*. macOS
     adds VoiceType to the list in Privacy & Security and offers to open it; just **switch VoiceType
     on**, there's no need to add it with +. Also set "Press 🌐 key to" to **Do Nothing** (or pick
     ⌥ Space, which needs no Input Monitoring). If macOS asks to *Quit & Reopen* VoiceType, do;
     setup carries on where it was.
   * **Speech model**: click **Download** (your browser downloads one 548 MB file), then **Import…**
     and choose `ggml-large-v3-turbo-q5_0.bin` in Downloads. VoiceType checks its size and SHA-256,
     copies it into its private container, and you can delete the download.

That's the only download: the voice-activity model ships inside the app, and Whisper is the default
engine for English and Hindi.

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

* The **flow bar** at the bottom of the screen appears only while you dictate: level bars while you
  talk, a timer with ✕ and ■ in hands-free mode, "Typing…", or a one-line notice with a **Fix**
  button. (Want a small sliver there when idle too? Settings → Advanced → *Show the flow bar when idle*.)
* The **VoiceType window** (menu bar → *Open VoiceType…*) has three tabs: **History** (search and
  re-copy what you said), **Dictionary** and **Styles**. The gear button opens **Settings**.
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

## Models

The same files as the phone (`voiceapk/models`):

| Folder | Files | Notes |
|---|---|---|
| `vad/` | `silero_vad.onnx` | required (auto-stop) |
| `moonshine/` | `preprocess.onnx`, `encode.int8.onnx`, `uncached_decode.int8.onnx`, `cached_decode.int8.onnx`, `tokens.txt` | Fast English (RTF ≈ 0.01 on Apple silicon) |
| `whisper/` | `small-encoder.int8.onnx`, `small-decoder.int8.onnx`, `small-tokens.txt` | Hindi + English |

**Default: whisper.cpp on the GPU.** The Setup's **Download** button fetches
**`ggml-large-v3-turbo-q5_0.bin`** (548 MB) from <https://huggingface.co/ggerganov/whisper.cpp>
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
`files.user-selected.read-only`, and **no** `com.apple.security.network.client` or `network.server`.
A sandboxed app without those can't open network connections; the kernel refuses them. You can
also turn Wi-Fi off and dictate normally, or watch `nettop -p VoiceType` (it never shows a
connection). Settings, history and models live only in
`~/Library/Containers/dev.offline.voicetype.mac/` and are excluded from Time Machine.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```bash
cd mac
scripts/build-dmg.sh      # fetches sherpa-onnx + whisper.cpp (checksum-verified), runs unit tests, builds,
                          # signs ad-hoc with the sandbox entitlements, verifies them, makes the DMG
open build/VoiceType.dmg
```

Self-test on a WAV file (unsandboxed dev binary):
```bash
DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib "$(swift build -c release --arch arm64 --show-bin-path)/VoiceType" \
  --selftest ../models some.wav hi whisper
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
