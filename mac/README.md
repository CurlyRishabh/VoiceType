# VoiceType for Mac: private, offline dictation

A menu-bar app that types what you say into any app. It runs entirely on your Mac: speech
recognition (sherpa-onnx with Moonshine / Whisper), the clean-up rules (the same rules and tests as
the Android app), and optional AI polish with Apple's **on-device** model. The app is
**sandboxed with no network entitlement**, so macOS itself blocks it from connecting anywhere.

## Install

1. Open `VoiceType.dmg` and drag **VoiceType** into **Applications**.
2. Open it from Applications. It lives in the menu bar (🎙 icon), with no Dock icon.
   This is a personal, ad-hoc-signed build. If macOS says it can't verify the developer
   (only when the DMG was downloaded or copied from elsewhere): **System Settings → Privacy & Security →
   Open Anyway**, or right-click the app → **Open**.
3. The **Setup** tab opens on first launch:
   * **Microphone**: click *Allow…*.
   * **Accessibility (auto-paste)**: click *Allow…*, then switch **VoiceType** on in the list.
     Without it, dictated text is copied and you press ⌘V yourself.
   * **Input Monitoring** for the fn key, and macOS's "Press 🌐 key to" set to **Do Nothing**.
   * **Models → Import models folder…**: choose the `models` folder that has `vad/`, `moonshine/`
     and `whisper/` inside (for example `voiceapk/models`). The files are copied into the app's
     private container, so the original folder can be deleted afterwards.

> Rebuilt the app? macOS ties permissions to the exact build for ad-hoc-signed apps. If dictation
> stops pasting after an update, remove VoiceType from Privacy & Security → Accessibility and add it again.

## Use

| Do this | What happens |
|---|---|
| **Hold fn** and talk | Records while you hold, through pauses. Release and the text is typed. |
| **Double-tap fn** | Hands-free: keeps listening until you **tap fn** again (or click ■ on the flow bar). |
| **esc** (or ✕) | Cancels; nothing is typed. |
| **fn + another key** | Works as normal (fn+arrows, F-keys); dictation ignores it. |

* The **flow bar** at the bottom of the screen shows what's happening: a small sliver when idle
  (click it to open VoiceType), level bars while you talk, a lock and timer in hands-free mode,
  "Typing…", or a one-line notice with a **Fix** button.
* Long hands-free dictations are transcribed sentence by sentence while you talk, so the text is
  ready almost as soon as you stop (limit: 15 minutes; holding: 5 minutes).
* **Styles** pick the AI-polish tone from the app you're typing in: Messages/Slack/WhatsApp →
  Casual, Mail/Outlook → Formal, Notes/Obsidian/Notion → bullet Notes, everything else → instant
  rules only. Change any of them in VoiceType → Styles.
* The **menu bar** icon has the last dictation (**Paste again** / Copy), language, the style for the
  current app, "Start hands-free dictation", and "Pause fn for 1 hour".
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

**Better Hindi on the Mac:** Whisper *large-v3-turbo* is much more accurate for Hindi and still
fast here (RTF ≈ 0.4). Put **only** these files in a `whisper/` folder instead of the small ones and import it:
`turbo-encoder.int8.onnx`, `turbo-decoder.int8.onnx`, `turbo-tokens.txt` from
<https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/tree/main> (~1 GB).

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
scripts/build-dmg.sh      # fetches sherpa-onnx (checksum-verified), runs unit tests, builds,
                          # signs ad-hoc with the sandbox entitlements, verifies them, makes the DMG
open build/VoiceType.dmg
```

Self-test on a WAV file (unsandboxed dev binary):
```bash
DYLD_LIBRARY_PATH=vendor/sherpa-onnx/lib .build/release/VoiceType --selftest ../models some.wav hi whisper
```

## Notes

* **Hindi fix (also applied to the Android app):** sherpa-onnx's Whisper decoder allows only 6
  output tokens per second of audio, which cut Hindi sentences off halfway. Hindi/auto chunks are
  now kept ≤ 8 s and padded with silence so the full sentence fits.
* The hot key uses Carbon `RegisterEventHotKey` (no Input Monitoring permission needed). ⌥ Space
  normally types a non-breaking space; pick another shortcut if you need that.
* Clipboard: the pasted text is marked *transient/concealed* so clipboard managers ignore it, and your
  previous clipboard is restored half a second later.
