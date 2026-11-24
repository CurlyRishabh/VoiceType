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
        let l = MeetingTranscript.lines(MeetingFiles.readSegments(e.folder))
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

    /// New title in meeting.json and transcript.md; the folder follows unless it is still being written.
    @discardableResult
    func rename(_ e: Entry, to title: String, folderInUse: Bool) -> Entry? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != e.info.title else { return e }
        var info = e.info
        info.title = t
        var folder = e.folder
        if !folderInUse {
            let name = MeetingFiles.folderName(start: info.startedAt, title: t)
            if name != folder.lastPathComponent {
                let dest = MeetingFiles.uniqueFolder(in: root, name: name)
                if (try? FileManager.default.moveItem(at: folder, to: dest)) != nil { folder = dest }
            }
        }
        try? MeetingFiles.writeInfo(info, to: folder)
        if info.status == .ready { try? MeetingFiles.writeMarkdown(MeetingFiles.readSegments(folder), info: info, to: folder) }
        refresh()
        return entry(folder.lastPathComponent)
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
    @Published private(set) var title = "Meeting"

    var onPhase: ((Phase) -> Void)?
    var onTick: (() -> Void)?
    var onLevel: ((MeetingChannel, Float) -> Void)?
    var onNotice: ((Notice) -> Void)?
    var onFinished: ((MeetingStore.Entry) -> Void)?
    var onRecovered: ((MeetingStore.Entry) -> Void)?
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
    private var startedAt: Date?
    private var limit = MeetingLimit(minutes: MeetingLimit.defaultMinutes)
    private var timer: Timer?
    private var ticks = 0
    private var diskWarned = false
    private var micSilentWarned = false
    private var sleepObserver: NSObjectProtocol?

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

    func start() {
        guard phase == .idle else { return }
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
        let free = (try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard DiskSpace.level(freeBytes: free) != .critical else {
            notice(.init(text: "Not enough disk space to record a meeting", seconds: 6))
            return
        }
        guard confirmConsentOnce() else { return }

        let start = Date()
        var info = MeetingInfo(title: "Meeting", startedAt: start)
        info.languageSetting = UserDefaults.standard.string(forKey: Key.language) ?? "en"
        info.model = Self.modelName(spec, models)
        info.audioKept = UserDefaults.standard.bool(forKey: Key.meetingKeepAudio)
        var created: URL?
        do {
            let folder = try store.create(start: start, title: info.title)
            created = folder
            try MeetingFiles.writeInfo(info, to: folder)
            let pipeline = try MeetingPipeline(config: config(folder, spec, vad), speech: speech, startHostTime: AudioGetCurrentHostTime())
            wire(pipeline)
            let mic = MicCapture()
            mic.onAudio = { [weak pipeline] s, peak, host in pipeline?.append(.me, s, peak: peak, hostTime: host) }
            mic.onSwitch = { [weak self] name in DispatchQueue.main.async { self?.notice(.init(text: "Recording from \(name)", seconds: 3)) } }
            try mic.start()
            let system = SystemAudioCapture()
            system.onAudio = { [weak pipeline] s, peak, host in pipeline?.append(.others, s, peak: peak, hostTime: host) }
            do {
                try system.start()
                systemAudio = .unknown
                self.system = system
            } catch {
                NSLog("VoiceType meeting: no system audio: %@", error.localizedDescription)
                systemAudio = .unavailable
                notice(.init(text: "Recording your mic only", action: "Turn on", run: SystemAudioPermission.openSettings, seconds: 8))
            }
            self.mic = mic
            self.pipeline = pipeline
            self.folder = folder
            self.info = info
        } catch {
            if let created { try? FileManager.default.removeItem(at: created) }
            notice(.init(text: "Couldn’t start recording: \(error.localizedDescription)", seconds: 6))
            return
        }

        startedAt = start
        elapsed = 0
        words = 0
        title = info.title
        ticks = 0
        diskWarned = false
        micSilentWarned = false
        limit = MeetingLimit(minutes: UserDefaults.standard.integer(forKey: Key.meetingMaxMinutes))
        currentID = folder?.lastPathComponent
        speech.hold(true)
        speech.warmUp(spec)
        MeetingNotifier.requestAuthorization()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        store.refresh()
        setPhase(.recording)
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
        p.onLevel = { [weak self] ch, level in DispatchQueue.main.async { self?.onLevel?(ch, level) } }
        p.onWords = { [weak self] n in DispatchQueue.main.async { self?.words = n } }
        p.onSilence = { [weak self] ch, state in DispatchQueue.main.async { self?.silence(ch, state) } }
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

    // MARK: while recording

    private func tick() {
        guard phase == .recording, let startedAt else { return }
        elapsed = Int(Date().timeIntervalSince(startedAt))
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
        ticks += 1
        if ticks % 30 == 0 { checkDisk(); saveProgress() }
        onTick?()
    }

    private func checkDisk() {
        let free = (try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        switch DiskSpace.level(freeBytes: free) {
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
        guard var info, let folder else { return }
        info.durationSeconds = Double(elapsed)
        info.systemAudio = systemAudio
        self.info = info
        try? MeetingFiles.writeInfo(info, to: folder)
    }

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
        if let t = store.entry(folder.lastPathComponent)?.info.title { info.title = t } // renamed while recording
        try? MeetingFiles.writeInfo(info, to: folder)
        self.info = info
        if systemAudio != .unknown { UserDefaults.standard.set(systemAudio.rawValue, forKey: Key.systemAudioState) }
        store.refresh()
        setPhase(.finishing)
        let echo = UserDefaults.standard.bool(forKey: Key.meetingEchoFilter)
        let keep = UserDefaults.standard.bool(forKey: Key.meetingKeepAudio)
        pipeline.finish { [weak self] outcome in
            let done = MeetingPipeline.write(outcome, info: info, folder: folder, echoFilter: echo, keepAudio: keep, stoppedAt: stoppedAt)
            DispatchQueue.main.async { self?.finished(done, folder: folder) }
        }
    }

    private func finished(_ info: MeetingInfo, folder: URL) {
        pipeline = nil
        self.info = nil
        self.folder = nil
        currentID = nil
        words = info.wordCount
        speech.hold(false)
        store.refresh()
        setPhase(.idle)
        if let entry = store.entry(folder.lastPathComponent) { onFinished?(entry) }
    }

    /// The app is quitting: close the WAVs so nothing is lost. The next launch transcribes them.
    func prepareForQuit() {
        guard phase == .recording, let pipeline, var info, let folder else { return }
        timer?.invalidate()
        mic?.stop()
        system?.stop()
        pipeline.closeFiles()
        info.status = .transcribing
        info.stopReason = .quit
        info.endedAt = Date()
        info.systemAudio = systemAudio
        try? MeetingFiles.writeInfo(info, to: folder)
    }

    // MARK: recovery

    /// Meetings left "recording" or "transcribing" by a crash or quit: transcribe their WAVs now, one
    /// at a time.
    func recoverInterrupted() {
        guard recoveryPipeline == nil, let spec = AppSettings.meetingSpec(models), let vad = models.vadFile else { return }
        let pending = store.entries.filter { ($0.info.status == .recording || $0.info.status == .transcribing) && $0.id != currentID }
        guard let entry = pending.first else { return }
        var info = entry.info
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
        do {
            let p = try MeetingPipeline(config: config(entry.folder, spec, vad), speech: speech, startHostTime: nil, writeAudio: false)
            recoveryPipeline = p
            p.ingestRecordedAudio()
            let echo = UserDefaults.standard.bool(forKey: Key.meetingEchoFilter)
            let keep = UserDefaults.standard.bool(forKey: Key.meetingKeepAudio)
            let base = info
            p.finish { [weak self] outcome in
                MeetingPipeline.write(outcome, info: base, folder: entry.folder, echoFilter: echo, keepAudio: keep, stoppedAt: nil)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.recoveryPipeline = nil
                    self.store.refresh()
                    if let e = self.store.entry(entry.id) { self.onRecovered?(e) }
                    self.recoverInterrupted()
                }
            }
        } catch {
            info.status = .failed
            info.error = error.localizedDescription
            try? MeetingFiles.writeInfo(info, to: entry.folder)
            store.refresh()
        }
    }

    // MARK: helpers

    private func setPhase(_ p: Phase) {
        phase = p
        onPhase?(p)
    }

    private func notice(_ n: Notice) { onNotice?(n) }
}
