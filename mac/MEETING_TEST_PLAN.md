# Meeting transcription: test plan

## Covered automatically

* `swift test`: the pure parts in VoiceTypeCore (`Tests/VoiceTypeCoreTests/MeetingTests.swift`):
  line merging, timestamps, echo de-dup, per-chunk hallucination filter, meeting-safe clean-up,
  transcript.md / transcript.json / meeting.json, folder names, WAV writer/reader and crash repair,
  channel alignment, live chunking (checked equal to `AudioChunker.plan` on random segments),
  silence watch, downmix and tap-buffer selection, length and disk guards.
* `scripts/test-meeting.sh`: the whole pipeline headless (`VoiceType --meeting`) on a synthetic
  call made with macOS voices: two channels, pauses, crosstalk, a Hindi line, echo of the others in
  the mic. Checks speakers, words, Hinglish output, echo removal, timestamp order and clock, the
  three files, and prints decode time / RTF.
* `scripts/test-audio.sh`: dictation is unchanged (language per call did not change its output).

## Manual test plan

Needs the signed app (`scripts/build-dmg.sh`), real permissions and real meeting apps. Ad-hoc
builds reset permissions on every rebuild: remove VoiceType from each Privacy & Security list
first if something looks denied. Where a step says "check the folder", that is
`~/Library/Application Support/VoiceType/Meetings/<date time title>/`.

### 1. Permissions and first run
1. Fresh permissions: press **⌃⌥R**. Expect the one-time "Before you record a meeting" alert;
   *Cancel* does nothing, *Start recording* starts. It never shows again.
2. Expect macOS's **System Audio Recording** prompt (wording from `NSAudioCaptureUsageDescription`)
   and, once, the notification permission prompt. Allow both.
3. **The main go/no-go:** play a YouTube video or join a call. The flow bar meter turns teal when
   the other side talks, and after Stop the transcript has **Others** lines. This proves the process
   tap and private aggregate device work inside the App Sandbox with the unchanged entitlements.
4. Deny System Audio Recording (or switch it off in Privacy & Security → Screen & System Audio
   Recording), record again while audio plays: after ~8 s the notice "Recording your mic only…"
   with *Turn on* (opens that pane); the pill shows a crossed-out speaker; the Meetings tab card
   shows the orange banner; transcript.md has the "only Me was transcribed" note; Settings →
   Meetings → System audio says "Silent in your last meeting".
5. With the mic denied: *Start recording* says "Microphone is blocked for VoiceType" and records nothing.

### 2. Real calls
For each of Zoom, Google Meet (Chrome and Safari), Microsoft Teams, a Slack huddle, FaceTime:
1. Record 3–5 minutes with headphones. Others' lines are the other people; Me lines are yours;
   timestamps match the call (spot-check two lines against a clock).
2. Repeat on the laptop speakers (no headphones). Few or no of the others' sentences appear as Me
   (echo de-dup). Turn *Remove echo when not using headphones* off and compare: the echoes appear.
3. Talk over each other for a few seconds: both sides' words are kept.
4. One Hindi/Hinglish meeting with Language = Both: Hindi lines come out in Latin (or Devanagari
   if chosen); English stays English.

### 3. Dictation during a meeting (two consumers of the mic)
1. While a meeting records, hold **fn** and dictate into Notes. Dictation works normally (listening
   pill, text typed), then the flow bar returns to the meeting pill.
2. Hands-free dictation (double-tap fn) for ~30 s during the meeting: works; the meeting keeps
   recording (timer keeps going, transcript has no gap; the dictated words also appear as Me —
   expected, it's your voice).
3. Dictation feels as fast as without a meeting (it waits for at most one meeting chunk).
4. If dictation fails to start during a meeting on some device ("Microphone error"), note the mic
   model: that device does not allow the meeting's IOProc and dictation's engine at once.

### 4. Devices
1. Connect AirPods mid-meeting (they become input and output): notice "Recording from AirPods…",
   both channels continue; after Stop, timestamps after the switch are still in step with the call.
2. Unplug a USB/3.5 mm headset mid-meeting: same.
3. Switch the output device in Control Centre while the other side talks: Others continues.

### 5. Stop paths and recovery
1. Stop via ⌃⌥R, the flow bar ■, the menu bar item (shows the elapsed time), and the Meetings tab:
   each shows "Wrapping up…" with a spinner for a few seconds, then "Transcript ready · Open" and a
   macOS notification; both open the meeting.
2. Close the lid (or Apple menu → Sleep) mid-meeting: after wake, "Transcript ready: stopped when
   your Mac went to sleep".
3. Quit from the menu bar mid-meeting, relaunch: after ~2 s "Transcribed an interrupted meeting";
   the meeting is complete up to the quit.
4. `kill -9` the app mid-meeting, relaunch: same as 3 (meeting.json stop reason `crash`).
5. Length limit: `defaults write dev.offline.voicetype.mac meeting_max_minutes -int 6`, record:
   warning at 1:00 (flow bar + notification), automatic stop and save at 6:00. Then
   `defaults delete dev.offline.voicetype.mac meeting_max_minutes`.
6. Start and stop within a few seconds without talking: "Started by mistake? Only N words" with
   *Discard*; Discard removes the meeting, ignoring it keeps it.
7. Low disk (only if a nearly full volume is at hand): warning under an hour left, stop when nearly full.

### 6. Flow bar and screen sharing
1. Pill: pulsing red dot, white/teal meter, timer (h:mm:ss past an hour), ■. Hover: widens to show
   the title and word count. Rename the meeting while recording: the hover shows the new title.
2. With *Hide from screen sharing while recording* on (default), share the screen in Zoom/Meet and
   take a ⌘⇧5 screen recording: the pill and the VoiceType window are not in them. Off: they are.
3. Notices that arrive while you dictate wait until the dictation is done.

### 7. Meetings tab
1. List: title, "Today at …", length, words, status chip (Recording with a live timer while
   recording, Transcribing, Ready, Failed). Search finds a word from inside a transcript.
2. Detail: rename (Return) renames meeting.json, transcript.md's title and the folder; find shows
   "n of m" and next/previous scroll to the line; Copy transcript / Copy for AI paste correctly
   into Claude or Codex; Show in Finder selects transcript.md; Delete asks, then removes the folder.
3. *Keep audio after transcription* off: the folder has no WAVs after Ready. On: mic.wav and
   system.wav stay and play in QuickTime, in sync with each other.

### 8. Long meeting
Record a real 60–90 minute meeting: memory stays flat in Activity Monitor (no growth with length),
dictation stays responsive, the transcript is ready seconds after Stop, and meeting.json's `rtf`
and `tailSeconds` are recorded (also in Settings → Advanced → Debug as "meeting · …").

### 9. Shortcut
1. Settings → Meetings → shortcut off: ⌃⌥R does nothing; on again: works.
2. With VoiceOver on, ⌃⌥ is VoiceOver's modifier: check whether ⌃⌥R still reaches VoiceType.
