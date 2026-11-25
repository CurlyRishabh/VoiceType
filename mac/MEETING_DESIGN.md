# Meeting transcription: design note

Local, offline meeting transcription. Two channels (mic = **Me**, sound of other apps = **Others**),
transcribed while the meeting runs, so the transcript is ready seconds after Stop. No summary, no
cloud, no new dependency, no entitlement change.

## Data flow

```
mic (HAL IOProc, default input) ──┐                      ┌─ mic.wav     (16-bit, 16 kHz, on disk as it records)
                                  ├─ 16 kHz mono ─ align ┤
process tap + private aggregate ──┘   (host time)        └─ system.wav
        │                                   │
        │                         Silero VAD per channel ─ LiveChunker (= AudioChunker.plan, incremental)
        │                                   │
        │                         chunk queue: ONE chunk per SpeechHost call (dictation can cut in)
        │                                   │ read the chunk back from the WAV (never the whole meeting in RAM)
        │                         whisper.cpp: text + segment t0/t1, language passed per call
        │                                   │
        │                         per-chunk hallucination filter, cross-chunk repeat drop,
        │                         meeting-safe clean-up (no commands / corrections / fillers)
        ▼                                   ▼
  silence watch ("mic only")     Stop: flush VAD tails → decode the rest ("Wrapping up…")
                                  → echo de-dup → merge same-speaker lines → transcript.md / .json
```

## Spec item → where

| Spec | File / type |
|---|---|
| System-audio tap (all output minus VoiceType), private aggregate, 16 kHz mono | `VoiceTypeApp/AudioCapture.swift`: `SystemAudioCapture` (tap + aggregate), `DeviceCapture` (HAL IOProc on any device, Float32 → mono → `AVAudioConverter` → 16 kHz, host-time stamps) |
| Mic capture for the meeting, dictation still works | `MicCapture` (same `DeviceCapture`, default input, follows default-device changes). A HAL IOProc is a separate client of the input device, so dictation's `AVAudioEngine` and the meeting run side by side (see "Two mic consumers" below) |
| Write each channel to disk as it records; crash-safe | `VoiceTypeCore/MeetingAudio.swift`: `WavWriter` (pwrite, header patched every 5 s and on close), `WavReader` (range reads, header repair after a crash) |
| Channels aligned by capture timestamps | `ChannelAligner` (Core): host time → expected sample position; gaps (late start, device restart) are filled with silence, jitter/drift ignored, audio never dropped |
| Permission denied → "Recording your mic only" | `SilenceWatch` (Core) on raw tap buffers; `MeetingController` shows the notice, Settings shows the last state |
| VAD per channel → `AudioChunker.plan` → one chunk per call | `MeetingPipeline` (App) + `LiveChunker` (Core, tested equal to `AudioChunker.plan`) |
| Language per call, no reload | `SpeechRecognizing.transcribe(_:prompt:language:)`; `SpeechHost` reloads only when the *model* changes (whisper.cpp takes the language per call; sherpa-onnx still bakes it in) |
| Keep the model loaded while recording | `SpeechHost.hold(_:)`: idle release skipped, memory *warning* ignored; a *critical* release reloads on the next chunk |
| Timestamps | `WhisperCppRecognizer.transcribeTimed` (`whisper_full_get_segment_t0/t1`); sherpa: one segment per chunk |
| Meeting-safe clean-up | `MeetingCleanup` (Core): Transliterator + `RuleCleaner` with commands, corrections, fillers and final punctuation off; capitals + dictionary kept |
| Per-chunk hallucination filter, cross-chunk repeats, near-silent chunks | `MeetingTextFilter` (Core) + `AudioLevel.isNearSilent` |
| Echo de-dup (no headphones) | `EchoFilter` (Core): drop a Me segment when ≥ 80 % of its words sit in runs of ≥ 3 words that Others said inside the Me segment's own time span (±1.5 s; word times spread evenly over each Others segment); under 4 words only on an exact match with an Others line that overlaps it in time (a mirrored reply comes after, an echo is simultaneous). Setting, default on |
| RTF per meeting | `MeetingPipeline` sums decode time; `meeting.json` `rtf`, `tailSeconds`; NSLog; Debug perf log |
| transcript.md / transcript.json / meeting.json | `MeetingRender`, `MeetingFiles`, `MeetingInfo` (Core) |
| Keep audio setting | `Key.meetingAudioDays` (default 7; 0 = delete once the transcript is final, -1 = forever) |
| ⌃⌥R, menu item, main-window button | `KeyMonitor` (`HotKey` id 3), `AppDelegate` menu, `MeetingsView` |
| Flow bar meeting mode | `FlowBar`: `.meeting` phase (red dot, timer, two-tone meter, stop, hover = title + words, "Wrapping up…") — dictation still takes the bar while it runs, then it returns to the meeting pill |
| Hide from screen capture | `NSWindow.sharingType = .none` on the flow bar and main window while recording (`Key.meetingHideFromCapture`, default on) |
| Meetings tab | `VoiceTypeApp/MeetingsView.swift` (list + detail), `MeetingStore` |
| Guards | `MeetingLimit`, `DiskSpace` (Core); sleep/quit/low disk/limit in `MeetingController`; "Started by mistake?" < 20 words; recovery of interrupted meetings at launch |
| Settings, permissions row, consent | `SettingsPane` "Meetings" section, `SystemAudioPermission`, onboarding microphone step, one-time consent alert |
| Headless test | `Headless.meeting` (`--meeting mic.wav system.wav [models] [lang]`), `scripts/test-meeting.sh` |

## Decisions

* **HAL IOProcs for both channels.** The tap must be read through an IOProc on the aggregate
  device anyway; using the same code for the mic gives both channels the same host-time clock and
  avoids a second `AVAudioEngine` input node. Several IOProcs on one device are a normal Core Audio
  case (it is how several apps share a mic), so dictation's engine and the meeting's IOProc coexist.
  The IOProc runs on the real-time IO thread and only copies the samples; downmix and resampling
  run on a queue. Formats are checked (32-bit float) and rate/layout changes reopen the capture.
* **Never block on Core Audio from the main thread.** Captures open and close on their own control
  queues; the aggregate is created without "tap auto start" (which makes `AudioDeviceStart` wait for
  the first tapped audio, forever if nothing plays). A switch opens the new device before closing
  the old one, and the old one's audio is used until the new one's first buffer; failures retry
  with a backoff. Every reopen is logged with what changed; unforced reopens are debounced (2 s)
  and capped (3 a minute). A 5 s no-buffers watchdog (time since the last *buffer*, not since the
  last open) reports one incident per channel, nudges with a growing pause, and says "back" only
  when a buffer arrives after the incident began.
* **Tap buffers are taken from the end of the aggregate's buffer list.** The aggregate clocks off the
  default output device (Apple's sample does this); if that device also has inputs (a headset), their
  streams come first and the tap's stream last.
* **Chunks are read back from the WAV**, not kept in RAM: memory stays flat for a 3-hour meeting.
* **One chunk in flight.** The meeting never queues more than one job on `SpeechHost`'s serial
  queue, so a dictation waits for at most one ≤ 25 s chunk (≈ 0.3–1 s on Apple silicon).
* **Recovery re-transcribes from the WAVs** (VAD → chunks → decode) instead of persisting partial
  results: simpler, and at the measured RTF an hour of audio is a couple of minutes. Saving order
  is transcript → meeting.json → delete audio, so a crash leaves either the audio or a complete
  transcript (recovered as ready). A failed chunk is retried once; any that still fail make the
  meeting "partial" and keep its audio.
* **Meetings need Whisper** (whisper.cpp preferred). With only Moonshine, English-only meetings work
  with chunk-level timestamps. A Moonshine dictation during a Whisper meeting reloads models.

## Two mic consumers

Dictation keeps its own `AVAudioEngine`; the meeting opens a separate HAL IOProc on the default input
device. Not verifiable here without a mic permission prompt, so it is in the manual test plan. If it
ever fails on some device, the fallback is to feed dictation from the meeting's mic stream (the
meeting already has 16 kHz mono with VAD) — not implemented.
