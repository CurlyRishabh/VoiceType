import AppKit
import AVFoundation
import CoreAudio
import Foundation
import UserNotifications
import VoiceTypeCore

/// The meetings on disk: `~/Library/Application Support/VoiceType/Meetings/`, one folder each (inside
/// the one home-folder path the sandbox opens, next to the models; Claude or Codex can read it there).
final class MeetingStore: ObservableObject {
    struct Entry: Identifiable, Equatable {
        var folder: URL
        var info: MeetingInfo
        var id: String { folder.lastPathComponent }
    }

    @Published private(set) var entries: [Entry] = []
    let root: URL
    /// A meeting's folder (its id) changed: old id, new id. Main thread.
    var onRename: ((String, String) -> Void)?
    private var linesCache: [String: [TranscriptLine]] = [:]
    private var textCache: [String: String] = [:]

    static var defaultRoot: URL {
        ModelStore.realHome.appendingPathComponent("Library/Application Support/VoiceType/Meetings", isDirectory: true)
    }

    init(root: URL = defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter(\.hasDirectoryPath)
        entries = folders.compactMap { f in MeetingFiles.readInfo(f).map { Entry(folder: f, info: $0) } }
            .sorted { $0.info.startedAt > $1.info.startedAt }
        linesCache = [:]
        textCache = [:]
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    func create(start: Date, title: String) throws -> URL {
        let folder = MeetingFiles.uniqueFolder(in: root, name: MeetingFiles.folderName(start: start, title: title))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func lines(_ e: Entry) -> [TranscriptLine] {
        if let l = linesCache[e.id] { return l }
        let l = MeetingTranscript.lines(MeetingFiles.readSegments(e.folder), notes: MeetingFiles.readNotes(e.folder))
        linesCache[e.id] = l
        return l
    }

    /// Title or transcript contains `query` (case-insensitive).
    func matches(_ e: Entry, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if e.info.title.lowercased().contains(q) { return true }
        if textCache[e.id] == nil { textCache[e.id] = lines(e).map(\.text).joined(separator: "\n").lowercased() }
        return textCache[e.id]!.contains(q)
    }

    /// New title in meeting.json and transcript.md; the folder follows unless it is still being
    /// written. Also brings a folder in line with a title set while it was in use.
    @discardableResult
    func rename(_ e: Entry, to title: String, folderInUse: Bool) -> Entry? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return e }
        var info = e.info
        let titleChanged = t != info.title
        info.title = t
        var folder = e.folder
        if !folderInUse {
            let name = MeetingFiles.folderName(start: info.startedAt, title: t)
            if !folder.lastPathComponent.hasPrefix(name) { // "<name> 2" (a duplicate) already fits
                let dest = MeetingFiles.uniqueFolder(in: root, name: name)
                if (try? FileManager.default.moveItem(at: folder, to: dest)) != nil {
                    folder = dest
                    onRename?(e.id, dest.lastPathComponent)
                }
            }
        }
        guard titleChanged || folder != e.folder else { return e }
        if titleChanged {
            try? MeetingFiles.writeInfo(info, to: folder)
            if info.status.hasTranscript { try? MeetingFiles.writeMarkdown(MeetingFiles.readSegments(folder), info: info, to: folder) }
        }
        refresh()
        return entry(folder.lastPathComponent)
    }

    /// A note added after the meeting, placed at its end; transcript.md is rewritten to include it.
    func addNote(_ e: Entry, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var notes = MeetingFiles.readNotes(e.folder)
        notes.append(MeetingNote(at: e.info.durationSeconds, text: t))
        try? MeetingFiles.writeNotes(notes, to: e.folder)
        if e.info.status.hasTranscript { try? MeetingFiles.writeMarkdown(MeetingFiles.readSegments(e.folder), info: e.info, to: e.folder) }
        refresh()
    }

    func delete(_ e: Entry) {
        try? FileManager.default.removeItem(at: e.folder)
        refresh()
    }
}

/// "Transcript ready" as a macOS notification (only in the real app bundle; the headless binary has
/// no bundle to post from).
enum MeetingNotifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, meetingID: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["meeting": meetingID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "meeting-\(meetingID)", content: content, trigger: nil))
    }
}

/// Starts, stops and finishes meeting recordings (main thread), and recovers ones the app didn't
/// finish. Owns the two captures and the pipeline; the UI reads its published state.
final class MeetingController: ObservableObject {
    enum Phase: Equatable { case idle, recording, finishing }

    struct Notice {
        let text: String
        var action: String?
        var run: (() -> Void)?
        var seconds: TimeInterval = 5
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed = 0
    @Published private(set) var words = 0
    @Published private(set) var systemAudio: MeetingInfo.SystemAudio = .unknown
    /// The meeting being recorded or finished (its folder name).
    @Published private(set) var currentID: String?
    /// The interrupted meeting being transcribed in the background.
    @Published private(set) var recoveringID: String?
    @Published private(set) var title = "Meeting"
    /// What has been transcribed so far in the meeting being recorded (live view), in arrival order.
    @Published private(set) var liveSegments: [TranscriptSegment] = [] { didSet { updateLiveLines() } }
    /// liveSegments (echo removed) and notes as transcript lines, rebuilt only when either changes.
    @Published private(set) var liveLines: [TranscriptLine] = []
    /// The note being typed in the live view (kept here so wrapping up doesn't discard it).
    @Published var noteDraft = ""
    /// Last time the others were clearly audible (uptime), so a call isn't treated as over while they talk.
    private(set) var othersHeardAt: TimeInterval = 0
    /// Notes typed during the current meeting.
    @Published private(set) var notes: [MeetingNote] = [] { didSet { updateLiveLines() } }
    /// The meeting being re-transcribed (it shares the recovery slot).
    @Published private(set) var retranscribingID: String?
    /// The current meeting was started for a call VoiceType detected (it may stop it when the call ends).
    private(set) var startedForCall = false

    var onPhase: ((Phase) -> Void)?
    var onTick: (() -> Void)?
    var onLevel: ((MeetingChannel, Float) -> Void)?
    var onNotice: ((Notice) -> Void)?
    var onFinished: ((MeetingStore.Entry) -> Void)?
    var onRecovered: ((MeetingStore.Entry) -> Void)?
    var onRetranscribed: ((MeetingStore.Entry) -> Void)?
    var onNeedsSetup: (() -> Void)?

    let store: MeetingStore
    private let models: ModelStore
    private let speech: SpeechHost
    private var pipeline: MeetingPipeline?
    private var recoveryPipeline: MeetingPipeline?
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var folder: URL?
    private var info: MeetingInfo?
    /// Monotonic start (system uptime), for the timer and the length limit.
    private var startUptime: TimeInterval = 0
    private var limit = MeetingLimit(minutes: MeetingLimit.defaultMinutes)
    private var timer: Timer?
    private var ticks = 0
    /// Between the first check and the recording actually starting (the consent alert is modal).
    private var starting = false
    private var diskWarned = false
    private var micSilentWarned = false
    /// A channel in trouble (no audio, or its device won't open): one incident, one notice when it
    /// starts and one when audio is back.
    private struct Trouble {
        /// Host time it began: only a buffer after this ends it.
        var began: UInt64
        /// The capture is failing to open a device (ends with a successful open, not just with audio
        /// from the old device).
        var openFailing: Bool
        var device: String?
        var nextNudge: TimeInterval
        var nudgeEvery: TimeInterval
    }
    private var trouble: [MeetingChannel: Trouble] = [:]
    private var recoveryTried = Set<String>()
    private var quitWaiters: [() -> Void] = []
    private var sleepObserver: NSObjectProtocol?

    /// No buffers at all from a channel for this long: the device is gone or stuck.
    static let stallSeconds = 5.0

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    init(models: ModelStore, speech: SpeechHost, store: MeetingStore) {
        self.models = models
        self.speech = speech
        self.store = store
        // A sleeping Mac records nothing: stop and save, like a manual stop.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(.sleep)
        }
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .finishing: notice(.init(text: "Still transcribing the last meeting", seconds: 2))
        }
    }

    // MARK: start

    /// `title`: what the meeting is called at first (a detected call names its app).
    func start(title startTitle: String = "Meeting", forCall: Bool = false) {
        guard phase == .idle, !starting else { return }
        guard let spec = AppSettings.meetingSpec(models), let vad = models.vadFile else {
            notice(.init(text: "Meetings need the Whisper speech model", action: "Fix", run: onNeedsSetup))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            notice(.init(text: "Allow the microphone, then start again"))
            return
        default:
            notice(.init(text: "Microphone is blocked for VoiceType", action: "Fix", run: onNeedsSetup))
            return
        }
        guard DiskSpace.level(freeBytes: freeBytes) != .critical else {
            notice(.init(text: "Not enough disk space to record a meeting", seconds: 6))
            return
        }
        starting = true
        defer { starting = false }
        // A second ⌃⌥R while this alert is up must not start a second meeting (`starting` above).
        guard confirmConsentOnce(), phase == .idle else { return }

        let start = Date()
        var info = MeetingInfo(title: startTitle, startedAt: start)
        info.languageSetting = UserDefaults.standard.string(forKey: Key.language) ?? "en"
        info.model = Self.modelName(spec, models)
        info.audioKept = AppSettings.meetingKeepsAudio
        let folder: URL
        let pipeline: MeetingPipeline
        do {
            folder = try store.create(start: start, title: info.title)
            do {
                try MeetingFiles.writeInfo(info, to: folder)
                pipeline = try MeetingPipeline(config: config(folder, spec, vad), speech: speech, startHostTime: AudioGetCurrentHostTime())
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        } catch {
            notice(.init(text: "Couldn’t start recording: \(error.localizedDescription)", seconds: 6))
            return
        }
        wire(pipeline)
        let mic = MicCapture(), system = SystemAudioCapture()
        wire(mic, .me, pipeline)
        wire(system, .others, pipeline)
        self.mic = mic
        self.system = system
        self.pipeline = pipeline
        self.folder = folder
        self.info = info

        startUptime = ProcessInfo.processInfo.systemUptime
        elapsed = 0
        words = 0
        title = info.title
        ticks = 0
        diskWarned = false
        micSilentWarned = false
        trouble = [:]
        liveSegments = []
        notes = []
        noteDraft = ""
        othersHeardAt = 0
        startedForCall = forCall
        systemAudio = .unknown
        limit = MeetingLimit(minutes: UserDefaults.standard.integer(forKey: Key.meetingMaxMinutes))
        currentID = folder.lastPathComponent
        speech.hold(true)
        speech.warmUp(spec)
        MeetingNotifier.requestAuthorization()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        store.refresh()
        setPhase(.recording)

        // Opening devices can take a second or two (Bluetooth): off the main thread.
        mic.start { [weak self] error in
            guard let self, let error, self.mic === mic else { return }
            self.abort("Couldn’t use the microphone: \(error.localizedDescription)")
        }
        system.start { [weak self] error in
            guard let self, let error, self.system === system else { return }
            NSLog("VoiceType meeting: no system audio: %@", error.localizedDescription)
            system.stop()
            self.system = nil
            self.systemAudio = .unavailable
            self.notice(.init(text: "Recording your mic only", action: "Turn on", run: SystemAudioPermission.openSettings, seconds: 8))
            self.onTick?()
        }
    }

    private var freeBytes: Int64 {
        (try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    private func config(_ folder: URL, _ spec: EngineSpec, _ vad: URL) -> MeetingPipeline.Config {
        let dictionary = AppSettings.dictionary
        let script = OutputScript(rawValue: UserDefaults.standard.string(forKey: Key.script) ?? "") ?? .latin
        let cpp = Recognizers.whisperCppModel(spec, modelsRoot: models.root) != nil
        return MeetingPipeline.Config(folder: folder, spec: spec, prompt: WhisperPrompt.build(dictionary.entries.map(\.to)),
                                      cleanup: MeetingCleanup(script: script, dictionary: dictionary), vadModel: vad,
                                      tokenBudget: !cpp && spec.kind == .hindiEnglish)
    }

    static func modelName(_ spec: EngineSpec, _ models: ModelStore) -> String {
        if let cpp = Recognizers.whisperCppModel(spec, modelsRoot: models.root) { return "whisper.cpp " + ModelLayout.whisperCppName(cpp) }
        return spec.kind == .fastEnglish ? "moonshine" : "whisper-onnx"
    }

    private func wire(_ p: MeetingPipeline) {
        p.onLevel = { [weak self] ch, level in
            DispatchQueue.main.async {
                if ch == .others, level > 0.15 { self?.othersHeardAt = ProcessInfo.processInfo.systemUptime }
                self?.onLevel?(ch, level)
            }
        }
        p.onWords = { [weak self] n in DispatchQueue.main.async { self?.words = n } }
        p.onSegments = { [weak self, weak p] new in
            DispatchQueue.main.async {
                guard let self, let p, self.pipeline === p else { return }
                self.liveSegments.append(contentsOf: new)
            }
        }
        p.onSilence = { [weak self] ch, state in DispatchQueue.main.async { self?.silence(ch, state) } }
        p.onWriteFailure = { [weak self] _, why in
            DispatchQueue.main.async {
                guard let self, self.phase == .recording else { return }
                self.notice(.init(text: "Couldn’t save the meeting audio (\(why)). Recording stopped", seconds: 10))
                self.stop(.writeError)
            }
        }
    }

    private func wire(_ c: ChannelCapture, _ ch: MeetingChannel, _ p: MeetingPipeline) {
        c.onAudio = { [weak p] a in p?.append(ch, a.samples, peak: a.peak, hostTime: a.hostTime, first: a.first) }
        c.onTrouble = { [weak self] why in
            guard let self, self.phase == .recording else { return }
            NSLog("VoiceType meeting: %@ trouble: %@", ch.rawValue, why)
            self.beginTrouble(ch, openFailing: true)
        }
        c.onSwitched = { [weak self] name, afterTrouble in
            guard let self, self.phase == .recording else { return }
            if afterTrouble {
                // Opened again; "back" is said once audio actually arrives (watchdog).
                self.trouble[ch]?.openFailing = false
                self.trouble[ch]?.device = name
            } else if ch == .me, self.trouble[ch] == nil {
                self.notice(.init(text: "Recording from \(name)", seconds: 3))
            }
        }
    }

    /// Starts an incident for `ch` unless one is going on (then it only notes an open failure).
    private func beginTrouble(_ ch: MeetingChannel, openFailing: Bool) {
        if trouble[ch] != nil {
            if openFailing { trouble[ch]?.openFailing = true }
            return
        }
        trouble[ch] = Trouble(began: AudioClock.now, openFailing: openFailing, device: nil,
                              nextNudge: ProcessInfo.processInfo.systemUptime, nudgeEvery: 5)
        let text: String
        switch (ch, openFailing) {
        case (.me, false): text = "No audio from the microphone: reconnecting…"
        case (.me, true): text = "Couldn’t open the microphone: retrying…"
        case (.others, false): text = "No audio from other apps: reconnecting…"
        case (.others, true): text = "Couldn’t capture other apps’ sound: retrying…"
        }
        notice(.init(text: text, action: ch == .me ? "Fix" : "Turn on", run: ch == .me ? onNeedsSetup : SystemAudioPermission.openSettings, seconds: 8))
        if ch == .others, !openFailing, systemAudio != .ok { systemAudio = .silent }
    }

    /// Only digital silence from a channel. For system audio that usually means System Audio
    /// Recording is off (or the prompt is still up); it also happens when nothing has played yet.
    private func silence(_ ch: MeetingChannel, _ state: SilenceWatch.State) {
        guard phase == .recording else { return }
        switch (ch, state) {
        case (.others, .silent):
            guard systemAudio != .unavailable else { return }
            systemAudio = .silent
            notice(.init(text: "Recording your mic only: no sound from other apps yet", action: "Turn on", run: SystemAudioPermission.openSettings, seconds: 8))
        case (.others, .sound):
            systemAudio = .ok
        case (.me, .silent) where !micSilentWarned:
            micSilentWarned = true
            notice(.init(text: "Your microphone is silent", action: "Fix", run: onNeedsSetup, seconds: 6))
        default:
            break
        }
        onTick?()
    }

    /// First meeting only: other people should know they are being recorded.
    private func confirmConsentOnce() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Key.meetingConsentShown) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Before you record a meeting"
        alert.informativeText = "VoiceType records your microphone and the sound of other apps (the people on your call) and transcribes both on this Mac. Let everyone in the meeting know you are recording: in many places, and under many company policies, recording people without their consent isn’t allowed."
        alert.addButton(withTitle: "Start recording")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: Key.meetingConsentShown)
        return true
    }

    /// The microphone couldn't be opened at all: nothing to save.
    private func abort(_ why: String) {
        guard phase == .recording else { return }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        pipeline?.finish { _ in } // seals and closes the files
        pipeline = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        info = nil
        currentID = nil
        speech.hold(false)
        store.refresh()
        setPhase(.idle)
        notice(.init(text: why, action: "Fix", run: onNeedsSetup, seconds: 8))
    }

    // MARK: while recording

    private func tick() {
        guard phase == .recording else { return }
        elapsed = Int(ProcessInfo.processInfo.systemUptime - startUptime)
        switch limit.check(elapsed: elapsed) {
        case .warn(let left)?:
            let text = "Meeting recording stops in \(left) min (the length limit)"
            notice(.init(text: text, action: "Settings", run: { [weak self] in self?.onNeedsSetup?() }, seconds: 8))
            MeetingNotifier.post(title: "Meeting recording", body: text + ". Change the limit in Settings › Meetings.", meetingID: currentID ?? "")
        case .stop?:
            stop(.maxLength)
            return
        case nil:
            break
        }
        watchdog()
        ticks += 1
        if ticks % 30 == 0 {
            checkDisk() // may stop the meeting
            saveProgress()
        }
        onTick?()
    }

    /// A channel that delivers no buffers at all (not even silence) is stuck or gone: say so once,
    /// ask the capture to open again with a growing pause (5, 10, 20… 60 s), and say "back" only when
    /// a buffer arrives after the trouble began. Reopening a device that then stays silent is not "back".
    private func watchdog() {
        let now = ProcessInfo.processInfo.systemUptime
        for (ch, capture) in [(MeetingChannel.me, mic as ChannelCapture?), (.others, system)] {
            guard let capture else { continue }
            if trouble[ch] == nil, capture.clock.secondsSinceAudio > Self.stallSeconds { beginTrouble(ch, openFailing: false) }
            guard var t = trouble[ch] else { continue }
            if !t.openFailing, capture.clock.hasBuffer(after: t.began) {
                trouble[ch] = nil
                let text = ch == .me ? "Microphone is back\(t.device.map { ": \($0)" } ?? "")" : "Other apps’ sound is back"
                notice(.init(text: text, seconds: 3))
                continue
            }
            if capture.clock.secondsSinceAudio > Self.stallSeconds, now >= t.nextNudge {
                capture.nudge(ifNoBufferSince: t.began)
                t.nextNudge = now + t.nudgeEvery
                t.nudgeEvery = min(60, t.nudgeEvery * 2)
                trouble[ch] = t
            }
        }
    }

    private func checkDisk() {
        switch DiskSpace.level(freeBytes: freeBytes) {
        case .critical:
            stop(.lowDisk)
            notice(.init(text: "Disk full: the meeting was stopped and saved", seconds: 8))
        case .low(let minutes) where !diskWarned:
            diskWarned = true
            notice(.init(text: "Storage almost full: about \(minutes) min of recording left", seconds: 8))
        default:
            break
        }
    }

    /// meeting.json keeps the length so far (the list shows it; recovery reads the WAVs anyway).
    private func saveProgress() {
        guard phase == .recording, var info, let folder else { return } // after a stop, meeting.json says "transcribing"
        info.durationSeconds = Double(elapsed)
        info.systemAudio = systemAudio
        info.title = title
        self.info = info
        try? MeetingFiles.writeInfo(info, to: folder)
    }

    /// While recording or wrapping up: the title goes to meeting.json now, the folder follows once finished.
    func rename(to newTitle: String) {
        guard isActive, let id = currentID, let entry = store.entry(id) else { return }
        if let e = store.rename(entry, to: newTitle, folderInUse: true) {
            info?.title = e.info.title
            title = e.info.title
        }
    }

    // MARK: stop

    func stop(_ reason: MeetingInfo.StopReason = .user) {
        guard phase == .recording, let pipeline, var info, let folder else { return }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        let stoppedAt = Date()
        info.status = .transcribing
        info.stopReason = reason
        info.endedAt = stoppedAt
        info.systemAudio = systemAudio
        info.title = title
        try? MeetingFiles.writeInfo(info, to: folder)
        self.info = info
        if systemAudio != .unknown { UserDefaults.standard.set(systemAudio.rawValue, forKey: Key.systemAudioState) }
        store.refresh()
        setPhase(.finishing)
        let echo = UserDefaults.standard.bool(forKey: Key.meetingEchoFilter)
        let keep = AppSettings.meetingKeepsAudio
        // finish() seals the channels first, so audio still in flight from the captures is ignored.
        pipeline.finish { [weak self] outcome in
            let done = MeetingPipeline.write(outcome, info: info, folder: folder, echoFilter: echo, keepAudio: keep, stoppedAt: stoppedAt)
            DispatchQueue.main.async { self?.finished(done, folder: folder) }
        }
    }

    private func finished(_ info: MeetingInfo, folder: URL) {
        let draft = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { // typed but not saved when the meeting ended: keep it
            var all = MeetingFiles.readNotes(folder)
            all.append(MeetingNote(at: info.durationSeconds, text: draft))
            try? MeetingFiles.writeNotes(all, to: folder)
            if info.status.hasTranscript { try? MeetingFiles.writeMarkdown(MeetingFiles.readSegments(folder), info: info, to: folder) }
        }
        noteDraft = ""
        pipeline = nil
        liveSegments = []
        notes = []
        startedForCall = false
        self.info = nil
        self.folder = nil
        currentID = nil
        words = info.wordCount
        speech.hold(false)
        store.refresh()
        // A title typed while it was wrapping up (meeting.json may have been written over), and a
        // folder still named after the old title: both catch up now.
        var entry = store.entry(folder.lastPathComponent)
        if let e = entry { entry = store.rename(e, to: title, folderInUse: false) ?? e }
        setPhase(.idle)
        let waiters = quitWaiters
        quitWaiters = []
        waiters.forEach { $0() }
        if let entry { onFinished?(entry) }
        purgeExpiredAudio()
    }

    /// The app wants to quit. A recording is stopped and saved as usual; while its transcript is
    /// being finished, `done` runs when it is ready or after `timeout`, whichever is first (the next
    /// launch finishes it otherwise). Returns false when there is nothing to wait for.
    func prepareToQuit(timeout: TimeInterval = 15, _ done: @escaping () -> Void) -> Bool {
        if phase == .recording { stop(.quit) }
        guard phase == .finishing else { return false }
        var called = false
        let once = { if !called { called = true; done() } }
        quitWaiters.append(once)
        let t = Timer(timeInterval: timeout, repeats: false) { _ in once() }
        RunLoop.main.add(t, forMode: .common)
        return true
    }

    // MARK: recovery

    /// Meetings left "recording" or "transcribing" by a crash or quit: transcribe their WAVs now, one
    /// at a time. A meeting whose transcript was already complete is just marked ready. Each meeting
    /// is tried once per launch, so one that can't be saved can't loop.
    func recoverInterrupted() {
        guard recoveryPipeline == nil else { return }
        sweepLeftoverAudio()
        purgeExpiredAudio()
        let pending = store.entries.filter {
            ($0.info.status == .recording || $0.info.status == .transcribing) && $0.id != currentID && !recoveryTried.contains($0.id)
        }
        guard let entry = pending.first else { return }
        recoveryTried.insert(entry.id)
        var info = entry.info
        let keep = AppSettings.meetingKeepsAudio

        // Killed after transcript.json was written but before meeting.json said so: its status
        // (saved with it) decides; transcript.md may be missing, so it is written again.
        if let recovered = MeetingFiles.recoveredInfo(info, folder: entry.folder, keepAudio: keep) {
            info = recovered.info
            try? MeetingFiles.writeMarkdown(recovered.segments, info: info, to: entry.folder)
            if (try? MeetingFiles.writeInfo(info, to: entry.folder)) != nil, !info.audioKept { MeetingFiles.deleteAudio(entry.folder) }
            store.refresh()
            recoverInterrupted()
            return
        }
        guard let spec = AppSettings.meetingSpec(models), let vad = models.vadFile else { return } // next launch, with a model
        guard !MeetingFiles.audioFiles(entry.folder).isEmpty else {
            info.status = .failed
            info.error = "The recording’s audio files are missing."
            try? MeetingFiles.writeInfo(info, to: entry.folder)
            store.refresh()
            recoverInterrupted()
            return
        }
        if info.status == .recording { info.stopReason = .crash }
        info.status = .transcribing
        try? MeetingFiles.writeInfo(info, to: entry.folder)
        store.refresh()
        transcribeFromDisk(entry, info: info, spec: spec, vad: vad, keepAudio: keep) { [weak self] e in
            if let e { self?.onRecovered?(e) }
        }
    }

    /// Runs a meeting's saved audio through the pipeline again (recovery, re-transcribe), in the one
    /// background slot. `done` gets the finished entry (main thread), then pending recoveries go on.
    /// `previous`: for a re-transcribe, the meeting as it was; if the new run fails it is put back
    /// untouched instead of a failed, empty transcript replacing a good one.
    private func transcribeFromDisk(_ entry: MeetingStore.Entry, info: MeetingInfo, spec: EngineSpec, vad: URL, keepAudio: Bool,
                                    previous: MeetingInfo? = nil, done: @escaping (MeetingStore.Entry?) -> Void) {
        var info = info
        do {
            let p = try MeetingPipeline(config: config(entry.folder, spec, vad), speech: speech, startHostTime: nil, writeAudio: false)
            recoveryPipeline = p
            recoveringID = entry.id
            p.ingestRecordedAudio()
            let echo = UserDefaults.standard.bool(forKey: Key.meetingEchoFilter)
            let base = info
            p.finish { [weak self] outcome in
                let failedAll = outcome.chunks > 0 && outcome.failedChunks >= outcome.chunks
                if var previous, failedAll {
                    if let onDisk = MeetingFiles.readInfo(entry.folder) { previous.title = onDisk.title }
                    previous.error = nil
                    try? MeetingFiles.writeInfo(previous, to: entry.folder)
                } else {
                    MeetingPipeline.write(outcome, info: base, folder: entry.folder, echoFilter: echo, keepAudio: keepAudio, stoppedAt: nil)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.recoveryPipeline = nil
                    self.recoveringID = nil
                    self.retranscribingID = nil
                    self.store.refresh()
                    // A title typed meanwhile: the folder follows now that it is free.
                    var e = self.store.entry(entry.id)
                    if let cur = e { e = self.store.rename(cur, to: cur.info.title, folderInUse: false) ?? cur }
                    if previous != nil, failedAll {
                        self.notice(.init(text: "Re-transcribing failed: the previous transcript is kept", seconds: 8))
                    } else {
                        done(e)
                    }
                    self.recoverInterrupted()
                }
            }
        } catch {
            if let previous {
                try? MeetingFiles.writeInfo(previous, to: entry.folder)
                notice(.init(text: "Couldn’t re-transcribe: \(error.localizedDescription)", seconds: 8))
            } else {
                info.status = .failed
                info.error = error.localizedDescription
                try? MeetingFiles.writeInfo(info, to: entry.folder)
            }
            retranscribingID = nil
            store.refresh()
            done(store.entry(entry.id))
        }
    }

    // MARK: re-transcribe, notes, audio

    /// Can `e` be transcribed again from its audio right now?
    func canRetranscribe(_ e: MeetingStore.Entry) -> Bool {
        e.id != currentID && recoveryPipeline == nil && phase == .idle
            && e.info.status != .recording && e.info.status != .transcribing && !MeetingFiles.audioFiles(e.folder).isEmpty
    }

    /// Transcribes a meeting again from its kept audio, in `language` ("en", "hi", "auto"). The old
    /// transcript stays until the new one is written; notes are kept.
    func retranscribe(_ e: MeetingStore.Entry, language: String) {
        guard canRetranscribe(e) else {
            notice(.init(text: phase == .idle ? "Can’t re-transcribe this meeting right now" : "Re-transcribe after the current meeting", seconds: 4))
            return
        }
        guard let spec = AppSettings.meetingSpec(models, language: language), let vad = models.vadFile else {
            notice(.init(text: "Re-transcribing needs the Whisper speech model", action: "Fix", run: onNeedsSetup))
            return
        }
        var info = e.info
        info.status = .transcribing
        info.languageSetting = language
        info.model = Self.modelName(spec, models)
        info.error = nil
        try? MeetingFiles.writeInfo(info, to: e.folder)
        recoveryTried.insert(e.id) // an interrupted re-transcribe falls back to the old transcript.json
        retranscribingID = e.id
        store.refresh()
        transcribeFromDisk(e, info: info, spec: spec, vad: vad, keepAudio: true, previous: e.info) { [weak self] done in
            if let done { self?.onRetranscribed?(done) }
        }
    }

    /// A note at the current point of the meeting being recorded.
    func addNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !t.isEmpty, let folder else { return }
        let at = phase == .recording ? ProcessInfo.processInfo.systemUptime - startUptime : Double(elapsed)
        notes.append(MeetingNote(at: at, text: t))
        try? MeetingFiles.writeNotes(notes, to: folder)
    }

    /// Deletes a finished meeting's audio now (the transcript stays; re-transcribing is no longer possible).
    func deleteAudio(_ e: MeetingStore.Entry) {
        guard e.id != currentID, e.id != recoveringID else { return }
        MeetingFiles.deleteAudio(e.folder)
        var info = e.info
        info.audioKept = false
        try? MeetingFiles.writeInfo(info, to: e.folder)
        store.refresh()
    }

    /// Audio past its keep period (Settings › Meetings) goes; the transcripts stay.
    func purgeExpiredAudio() {
        let days = AppSettings.meetingAudioDays
        for e in store.entries where e.id != currentID && e.id != recoveringID && AudioRetention.expired(e.info, days: days) {
            MeetingFiles.deleteAudio(e.folder)
            var info = e.info
            info.audioKept = false
            try? MeetingFiles.writeInfo(info, to: e.folder)
        }
        store.refresh()
    }

    /// A ready meeting whose audio should be gone but isn't (quit between saving and deleting).
    private func sweepLeftoverAudio() {
        for e in store.entries where e.info.status == .ready && !e.info.audioKept && e.id != currentID {
            MeetingFiles.deleteAudio(e.folder)
        }
    }

    // MARK: helpers

    private func updateLiveLines() {
        let segs = UserDefaults.standard.bool(forKey: Key.meetingEchoFilter) ? EchoFilter.apply(liveSegments).segments : liveSegments
        liveLines = MeetingTranscript.lines(segs, notes: notes)
    }

    /// Seconds since the others were last heard (infinite before they ever were).
    var secondsSinceOthersHeard: TimeInterval {
        othersHeardAt == 0 ? .infinity : ProcessInfo.processInfo.systemUptime - othersHeardAt
    }

    private func setPhase(_ p: Phase) {
        phase = p
        onPhase?(p)
    }

    private func notice(_ n: Notice) { onNotice?(n) }
}
