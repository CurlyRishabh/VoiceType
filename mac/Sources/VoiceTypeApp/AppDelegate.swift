import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import VoiceTypeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let models = ModelStore()
    let history = HistoryStore()
    let polisher = AppleIntelligencePolisher()
    lazy var speech = SpeechHost(modelsRoot: models.root)
    lazy var dictation = Dictation(models: models, speech: speech, polisher: polisher, history: history)
    let meetingStore = MeetingStore()
    lazy var meetings = MeetingController(models: models, speech: speech, store: meetingStore)
    /// Notices calls starting and ending in other apps (Settings › Meetings › When a call starts).
    let calls = CallDetector()
    private var purgeTimer: Timer?
    /// Watches the field a dictation went into for fixes worth adding to the Dictionary.
    private let corrections = CorrectionWatch()
    /// A call that started while a meeting was still active.
    private var missedCall: CallApps.App?
    let flowBar = FlowBar()

    private let keys = KeyMonitor()
    private var gesture = TriggerGesture()
    private var deadlineTimer: Timer?
    private var elapsedTimer: Timer?
    private var statusItem: NSStatusItem!
    private let mainModel = MainModel()
    private let onboardingModel = OnboardingModel()
    private lazy var mainToolbar = MainToolbar(model: mainModel) { [weak self] in self?.showSettings() }
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var licensesWindow: NSWindow?
    private var lastText: String?
    private var lastApp: String?
    /// A meeting notice that arrived while a dictation had the flow bar.
    private var noticeQueue: [MeetingController.Notice] = []
    /// Flow bar and windows kept out of screen capture (a meeting is on and the setting allows it).
    private var captureHidden = false

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One VoiceType at a time: two copies (an installed one and a fresh build, say) would both
        // hear the key and paste every dictation twice. The one already running wins.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            Diagnostics.log("second copy started; already running: \(other.bundleURL?.path ?? "?"); quitting")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "VoiceType is already running"
            alert.informativeText = "Another copy is open (\(other.bundleURL?.path ?? "unknown location")). Quit it first if you meant to use this one; two copies would type everything twice."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        AppSettings.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        flowBar.model.onStop = { [weak self] in self?.send(.stopButton) }
        flowBar.model.onMeetingStop = { [weak self] in self?.meetings.stop() }
        flowBar.model.onCancel = { [weak self] in self?.send(.cancelButton) }
        flowBar.model.onOpen = { [weak self] in self?.showMainWindow() }
        flowBar.model.onMeetingOpen = { [weak self] in
            guard let self, let id = self.meetings.currentID else { return }
            self.showMeeting(id)
        }

        keys.onTrigger = { [weak self] down, time in self?.send(down ? .keyDown(time) : .keyUp(time)) }
        keys.onHandsFreeKey = { [weak self] in self?.send(.handsFreeKey) }
        keys.onOtherKey = { [weak self] in self?.send(.otherKey) }
        keys.onEscape = { [weak self] in self?.send(.escape) }
        keys.onMeetingKey = { [weak self] in self?.meetings.toggle() }

        dictation.onState = { [weak self] s in self?.dictationState(s) }
        dictation.onLevel = { [weak self] in self?.flowBar.model.push($0) }
        dictation.onMessage = { [weak self] m in self?.flowBar.notice(m, action: "Fix", onAction: { self?.showOnboarding() }) }
        dictation.onEndedByItself = { [weak self] in self?.gesture.reset(); self?.stopTimers() }
        dictation.onBusy = { [weak self] in
            // Taps while the last dictation is still being typed used to vanish silently.
            self?.flowBar.notice("Still typing the last dictation", seconds: 1.5) {
                self?.dictation.state == .idle ? .idle : .typing
            }
        }
        dictation.onResult = { [weak self] r, target in self?.deliver(r.text, appName: target.appName) }

        meetings.onPhase = { [weak self] in self?.meetingPhase($0) }
        meetings.onTick = { [weak self] in self?.updateMeetingBar() }
        meetings.onLevel = { [weak self] ch, level in self?.flowBar.model.pushMeeting(ch, level) }
        meetings.onNotice = { [weak self] in self?.meetingNotice($0) }
        meetings.onFinished = { [weak self] in self?.meetingFinished($0) }
        meetings.onRecovered = { [weak self] e in
            self?.meetingNotice(.init(text: "Transcribed an interrupted meeting", action: "Open", run: { self?.showMeeting(e.id) }, seconds: 8))
        }
        meetings.onNeedsSetup = { [weak self] in self?.showSettings() }
        meetings.onRetranscribed = { [weak self] e in
            self?.meetingNotice(.init(text: e.info.status == .failed ? "Re-transcribing failed" : "Transcribed again",
                                      action: "Open", run: { self?.showMeeting(e.id) }, seconds: 8))
        }
        calls.onEvent = { [weak self] in self?.callEvent($0) }
        applyCallDetection()
        // Meeting audio past its keep period goes once an hour (and at launch, with recovery).
        let purge = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, !self.meetings.isActive else { return }
            self.meetings.purgeExpiredAudio()
        }
        RunLoop.main.add(purge, forMode: .common)
        purgeTimer = purge
        Diagnostics.log("launch: accessibility \(Permissions.isGranted(.accessibility) ? "on" : "OFF"), input monitoring \(Permissions.isGranted(.inputMonitoring) ? "on" : "OFF"), microphone \(Permissions.isGranted(.microphone) ? "on" : "OFF"), trigger \(TriggerKey.current.rawValue)")
        // A meeting open in the detail view follows its folder when that is renamed.
        meetingStore.onRename = { [weak self] old, new in
            if self?.mainModel.openMeeting == old { self?.mainModel.openMeeting = new }
        }
        if MeetingNotifier.available { UNUserNotificationCenter.current().delegate = self }
        // A meeting the app didn't finish (crash, quit while recording): transcribe its audio now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.meetings.recoverInterrupted() }

        applyTrigger()
        dictation.warmUp()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.keys.tapRunning else { return }
            self.applyTrigger() // Input Monitoring may have just been granted
        }

        installMainMenu()
        if !UserDefaults.standard.bool(forKey: Key.onboardingDone) || setupProblem != nil { showOnboarding() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening VoiceType again while it runs (Finder, Spotlight, Launchpad) shows its window, as other
    /// apps do. Without this a menu-bar app does nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !UserDefaults.standard.bool(forKey: Key.onboardingDone) { showOnboarding() } else { showMainWindow() }
        return false
    }

    /// whisper.cpp's Metal backend aborts the process at exit if a model is still loaded.
    func applicationWillTerminate(_ notification: Notification) { speech.releaseAndWait() }

    /// Key commands while a VoiceType window is in front (a menu-bar app shows no menus): ⌘, ⌘Q ⌘W ⌘M,
    /// and the Edit commands, without which ⌘C / ⌘V / ⌘Z do nothing in the app's text fields.
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let settings = item("Settings…", #selector(openSettings), ",")
        settings.target = self
        submenu("VoiceType", [
            settings, .separator(),
            item("Hide VoiceType", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit VoiceType", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        window.submenu = windowMenu
        main.addItem(window)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Quitting mid-meeting stops and saves it, and waits (up to 15 s) for the transcript to finish.
    /// If it takes longer, the audio is on disk and the next launch transcribes it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let wait = meetings.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return wait ? .terminateLater : .terminateNow
    }

    // MARK: trigger key -> gesture -> dictation

    func applyTrigger() {
        let ok = keys.start(TriggerKey.current)
        if !ok { NSLog("VoiceType: key listener not running yet (Input Monitoring)") }
    }

    private func send(_ event: TriggerGesture.Event) {
        // A double-tap may be as slow as a double-click (System Settings → Mouse/Trackpad), within reason.
        gesture.doubleTapWindow = min(max(NSEvent.doubleClickInterval, 0.35), 0.6)
        let effects = gesture.handle(event)
        effects.forEach(apply)
        scheduleDeadline()
    }

    private func apply(_ effect: TriggerGesture.Effect) {
        switch effect {
        case .begin:
            if !dictation.begin() { gesture.reset() }
        case .becameHold:
            break
        case .becameHandsFree:
            guard dictation.isRecording else { gesture.reset(); return }
            dictation.enterHandsFree()
            flowBar.model.elapsed = 0
            flowBar.set(.handsFree)
            elapsedTimer?.invalidate()
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let start = self.dictation.startedAt else { return }
                self.flowBar.model.elapsed = Int(Date().timeIntervalSince(start))
            }
        case .finish:
            stopTimers()
            dictation.finish()
        case .cancel:
            stopTimers()
            dictation.cancel()
            flowBar.set(.idle)
        }
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        guard let deadline = gesture.nextDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.005
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            // Queued, so a key press already on its way to the main thread is handled first and a
            // second tap that arrived in time is never mistaken for "no second tap".
            DispatchQueue.main.async { self?.send(.tick(ProcessInfo.processInfo.systemUptime)) }
        }
        RunLoop.main.add(timer, forMode: .common) // also while a menu is open
        deadlineTimer = timer
    }

    private func stopTimers() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func dictationState(_ s: Dictation.State) {
        refreshIcon()
        switch s {
        case .listening:
            flowBar.set(dictation.handsFree ? .handsFree : .listening)
        case .transcribing, .polishing:
            flowBar.set(.typing)
        case .idle:
            if flowBar.model.phase != .notice { flowBar.set(.idle) }
            if !noticeQueue.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showNextNotice() }
            }
        }
    }

    // MARK: meetings

    private func meetingPhase(_ p: MeetingController.Phase) {
        refreshIcon()
        applyCaptureHiding()
        if p == .idle { flowBar.setMeeting(nil) } else { updateMeetingBar() }
        mainModel.refresh += 1
        // A call that started while the last meeting was wrapping up: offer it now.
        if p == .idle, let app = missedCall, calls.activeCall == app {
            missedCall = nil
            callEvent(.started(app))
        }
    }

    /// While a meeting records (and the setting is on), the flow bar and every VoiceType window ask
    /// macOS to be left out of screen shares and recordings. Also called when the setting changes.
    func applyCaptureHiding() {
        captureHidden = meetings.isActive && UserDefaults.standard.bool(forKey: Key.meetingHideFromCapture)
        flowBar.hideFromCapture(captureHidden)
        for w in NSApp.windows { w.sharingType = captureHidden ? .none : .readOnly }
    }

    private func updateMeetingBar() {
        guard meetings.isActive else { return }
        let micOnly = meetings.systemAudio == .silent || meetings.systemAudio == .unavailable
        flowBar.setMeeting(.init(elapsed: meetings.elapsed, words: meetings.words, title: meetings.title,
                                 wrappingUp: meetings.phase == .finishing, micOnly: micOnly))
    }

    /// Notices with an action (meetings, calls, Dictionary) take turns: they wait while a dictation
    /// is using the flow bar or another one is showing, so a call prompt is never replaced.
    private func meetingNotice(_ n: MeetingController.Notice) {
        noticeQueue.append(n)
        showNextNotice()
    }

    private func showNextNotice() {
        guard dictation.state == .idle, flowBar.model.phase != .notice, !noticeQueue.isEmpty else { return }
        let n = noticeQueue.removeFirst()
        let run = n.run
        flowBar.model.onNoticeAction = { [weak self] in
            run?()
            self?.flowBar.set(.idle) // done with it (back to the meeting pill, if any)
            self?.showNextNotice()
        }
        flowBar.notice(n.text, action: n.run == nil ? nil : n.action, seconds: n.seconds) { [weak self] in
            DispatchQueue.main.async { self?.showNextNotice() }
            return .idle
        }
    }

    private func meetingFinished(_ e: MeetingStore.Entry) {
        mainModel.refresh += 1
        let info = e.info
        if info.status == .partial {
            meetingNotice(.init(text: "Transcript ready, but parts couldn’t be transcribed (audio kept)", action: "Open",
                                run: { [weak self] in self?.showMeeting(e.id) }, seconds: 10))
            return
        }
        if info.status == .failed {
            meetingNotice(.init(text: "The meeting transcript failed", action: "Open", run: { [weak self] in self?.showMeeting(e.id) }, seconds: 8))
            return
        }
        if MeetingLimit.looksAccidental(words: info.wordCount, seconds: info.durationSeconds) {
            meetingNotice(.init(text: "Started by mistake? Only \(info.wordCount) words", action: "Discard", run: { [weak self] in
                guard let self else { return }
                if self.mainModel.openMeeting == e.id { self.mainModel.openMeeting = nil }
                self.meetingStore.delete(e)
            }, seconds: 10))
            return
        }
        let why: String
        switch info.stopReason {
        case .sleep?: why = ": stopped when your Mac went to sleep"
        case .maxLength?: why = ": stopped at the length limit"
        case .lowDisk?: why = ": stopped, disk almost full"
        case .callEnded?: why = ": the call ended"
        default: why = ""
        }
        meetingNotice(.init(text: "Transcript ready\(why)", action: "Open", run: { [weak self] in self?.showMeeting(e.id) }, seconds: 8))
        MeetingNotifier.post(title: "Transcript ready", body: "\(info.title) · \(MeetingDates.duration(info.durationSeconds)) · \(info.wordCount.formatted()) words",
                             meetingID: e.id)
    }

    // MARK: learning from corrections

    private func learned(_ found: [PersonalDictionary.Entry]) {
        let entries = found.filter { !AppSettings.isUnlearned($0) }
        guard !entries.isEmpty else { return Diagnostics.log("learned nothing: those fixes were undone before") }
        let before = AppSettings.dictionary
        let dict = entries.reduce(before) { $0.learning($1) }
        AppSettings.dictionary = dict
        Diagnostics.log("learned \(entries.count) dictionary entr\(entries.count == 1 ? "y" : "ies")")
        let added = dict.entries.filter { !before.entries.contains($0) }
        let names = entries.map { "“\($0.to)”" }.joined(separator: ", ")
        let undo = { [weak self] in
            // Back to exactly what it was, unless the Dictionary was edited since (then only this lesson
            // is taken back). Either way it isn't learned again.
            if AppSettings.dictionary == dict {
                AppSettings.dictionary = before
            } else {
                var d = AppSettings.dictionary
                for x in added { d = d.minus(x.from) }
                for x in before.entries where !dict.entries.contains(x) { d = d.plus(x) }
                AppSettings.dictionary = d
            }
            AppSettings.unlearn(entries + added)
            self?.mainModel.entries = AppSettings.dictionary.entries
        }
        mainModel.entries = dict.entries // the Dictionary tab shows it at once
        // Through the meeting-notice path: it waits while a dictation has the flow bar.
        meetingNotice(.init(text: "Added \(names) to Dictionary", action: "Undo", run: undo, seconds: 10))
    }

    // MARK: calls in other apps

    /// Starts or stops the call detector to match Settings › Meetings.
    func applyCallDetection() {
        let mode = UserDefaults.standard.string(forKey: Key.meetingCallDetection) ?? "ask"
        if mode == "off" { calls.stop() } else { calls.start() }
    }

    private func callEvent(_ event: CallWatch.Event) {
        let mode = UserDefaults.standard.string(forKey: Key.meetingCallDetection) ?? "ask"
        guard mode != "off" else { return }
        Diagnostics.log("call: \(event), mode \(mode), meeting \(meetings.phase)")
        switch event {
        case .started(let app):
            guard meetings.phase == .idle else {
                if meetings.phase == .finishing { missedCall = app }
                return
            }
            // A browser holding the mic may be voice typing or an AI voice chat: always ask.
            if mode == "auto" && !app.isBrowser {
                meetings.start(title: app.meetingTitle, forCall: true)
            } else {
                meetingNotice(.init(text: "Call started in \(app.name). Record it?", action: "Record",
                                    run: { [weak self] in self?.meetings.start(title: app.meetingTitle, forCall: true) }, seconds: 15))
            }
        case .ended(let app):
            if missedCall == app { missedCall = nil }
            guard meetings.isRecording else { return }
            // Only when the others have also gone quiet: an app that releases the mic on mute isn't a hang-up.
            if mode == "auto" && meetings.startedForCall {
                stopWhenCallIsOver(app, checks: 0)
            } else {
                meetingNotice(.init(text: "Call in \(app.name) ended. Stop recording?", action: "Stop",
                                    run: { [weak self] in self?.meetings.stop() }, seconds: 15))
            }
        }
    }

    /// Auto-recorded call over: stop once the others have also been quiet for 20 s (people say
    /// goodbye after hanging up the mic in some apps). Checks every 10 s for up to 3 minutes; a
    /// call that comes back, or a manual stop, ends the checking.
    private func stopWhenCallIsOver(_ app: CallApps.App, checks: Int) {
        guard meetings.isRecording, meetings.startedForCall, calls.activeCall == nil else { return }
        if meetings.secondsSinceOthersHeard > 20 { meetings.stop(.callEnded); return }
        guard checks < 18 else {
            meetingNotice(.init(text: "Call in \(app.name) ended. Stop recording?", action: "Stop",
                                run: { [weak self] in self?.meetings.stop() }, seconds: 15))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.stopWhenCallIsOver(app, checks: checks + 1) }
    }

    /// The Meetings tab, opened on one meeting.
    func showMeeting(_ id: String) {
        mainModel.openMeeting = id
        mainModel.meetingTitleDraft = meetingStore.entry(id)?.info.title ?? ""
        mainModel.meetingFind = ""
        showMainWindow(.meetings)
    }

    // MARK: notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["meeting"] as? String, !id.isEmpty {
            DispatchQueue.main.async { self.showMeeting(id) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private func deliver(_ text: String, appName: String?) {
        lastText = text
        lastApp = appName
        let learn = UserDefaults.standard.bool(forKey: Key.learnCorrections)
        let field = learn ? Inserter.focusedField() : nil
        if field == nil {
            corrections.finish() // the last dictation's edits are judged now (a watched one: in `watch`)
            if learn { Diagnostics.log("corrections: no readable text field in \(appName ?? "?"): \(Inserter.lastMiss)") }
        }
        switch Inserter.insert(text) {
        case .pasted:
            if let field {
                corrections.watch(field, typed: text) { [weak self] learned in self?.learned(learned) }
            }
        case .copiedOnly:
            // No Accessibility (a fresh or re-signed build loses it): say why it didn't paste.
            flowBar.notice("Copied, not pasted: allow Accessibility", action: "Fix") { [weak self] in self?.showOnboarding(at: .typing) }
        }
    }

    // MARK: menu bar

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Nothing to say when all is well; only the one thing that needs fixing.
        if let problem = setupProblem {
            menu.addItem(item("\(problem). Fix…", #selector(openSetup)))
            menu.addItem(.separator())
        }

        if let lastText {
            menu.addItem(viewItem(lastDictationView(lastText)))
            menu.addItem(.separator())
        }
        menu.addItem(viewItem(languageView()))
        if UserDefaults.standard.string(forKey: Key.language) != "en" {
            let t = item("Translate to English", #selector(toggleTranslate))
            t.state = UserDefaults.standard.bool(forKey: Key.translate) ? .on : .off
            menu.addItem(t)
        }
        menu.addItem(.separator())

        let handsFree = item(dictation.isRecording ? "Finish dictation" : "Start hands-free", #selector(menuDictation))
        if KeyMonitor.handsFreeShortcutOn { // shown as a hint; the shortcut itself works everywhere
            handsFree.keyEquivalent = " "
            handsFree.keyEquivalentModifierMask = [.shift, .option]
        }
        menu.addItem(handsFree)
        let meeting: NSMenuItem
        switch meetings.phase {
        case .idle: meeting = item("Start meeting recording", #selector(toggleMeeting))
        case .recording: meeting = item("Stop meeting recording (\(FlowBarView.clock(meetings.elapsed)))", #selector(toggleMeeting))
        case .finishing:
            meeting = NSMenuItem(title: "Transcribing the meeting…", action: nil, keyEquivalent: "")
            meeting.isEnabled = false
        }
        if meetings.phase != .finishing, KeyMonitor.meetingShortcutOn { // a hint; the shortcut works everywhere
            meeting.keyEquivalent = "r"
            meeting.keyEquivalentModifierMask = [.control, .option]
        }
        menu.addItem(meeting)
        let sounds = item("Play start/stop sounds", #selector(toggleSounds))
        sounds.state = UserDefaults.standard.bool(forKey: Key.sounds) ? .on : .off
        menu.addItem(sounds)
        menu.addItem(item(keys.isPaused ? "Resume \(TriggerKey.current.title)" : "Pause \(TriggerKey.current.title) for 1 hour", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Meetings…", #selector(openMeetings)))
        menu.addItem(item("Open VoiceType…", #selector(openMain), key: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private static let menuWidth: CGFloat = 300
    private static let languages = [("en", "English"), ("hi", "हिंदी"), ("auto", "Both")]

    /// A menu row drawn by a view (AppKit controls keep working while the menu is open).
    private func viewItem(_ content: NSStackView) -> NSMenuItem {
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: Self.menuWidth).isActive = true
        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: Self.menuWidth, height: content.fittingSize.height)))
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let i = NSMenuItem()
        i.view = container
        return i
    }

    /// "Last dictation · Slack", the text (two lines at most), and Paste again / Copy.
    private func lastDictationView(_ text: String) -> NSStackView {
        let meta = NSTextField(labelWithString: "Last dictation\(lastApp.map { " · \($0)" } ?? "")")
        meta.font = .systemFont(ofSize: 11, weight: .medium)
        meta.textColor = .secondaryLabelColor
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .menuFont(ofSize: 0)
        body.maximumNumberOfLines = 2
        body.cell?.truncatesLastVisibleLine = true
        body.preferredMaxLayoutWidth = Self.menuWidth - 28
        body.isSelectable = false
        let buttons = NSStackView(views: [menuButton("Paste again", #selector(pasteAgain)), menuButton("Copy", #selector(copyLast))])
        buttons.spacing = 6
        let stack = NSStackView(views: [meta, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 14)
        return stack
    }

    private func menuButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return b
    }

    /// "Language" with the three choices one click away.
    private func languageView() -> NSStackView {
        let label = NSTextField(labelWithString: "Language")
        label.font = .menuFont(ofSize: 0)
        let picker = NSSegmentedControl(labels: Self.languages.map(\.1), trackingMode: .selectOne, target: self, action: #selector(languagePicked(_:)))
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        picker.setAccessibilityLabel("Language")
        let current = UserDefaults.standard.string(forKey: Key.language) ?? "en"
        picker.selectedSegment = Self.languages.firstIndex { $0.0 == current } ?? 0
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.addView(label, in: .leading)
        stack.addView(picker, in: .trailing)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        return stack
    }

    @objc private func pasteAgain() {
        statusItem.menu?.cancelTracking()
        guard let lastText else { return }
        // Let the menu close and focus return to the app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.deliver(lastText, appName: self.lastApp) }
    }

    @objc private func copyLast() {
        statusItem.menu?.cancelTracking()
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func languagePicked(_ sender: NSSegmentedControl) {
        guard Self.languages.indices.contains(sender.selectedSegment) else { return }
        UserDefaults.standard.set(Self.languages[sender.selectedSegment].0, forKey: Key.language)
        dictation.warmUp()
    }

    @objc private func toggleSounds() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Key.sounds), forKey: Key.sounds)
    }

    @objc private func toggleTranslate() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Key.translate), forKey: Key.translate)
        dictation.warmUp()
    }

    @objc private func openSetup() { showOnboarding() }

    @objc private func menuDictation() {
        if dictation.isRecording { send(.stopButton) } else { gesture.startHandsFree().forEach(apply) }
    }

    @objc private func openMain() { showMainWindow() }

    @objc private func openSettings() { showSettings() }

    @objc private func openMeetings() { showMainWindow(.meetings) }

    @objc private func toggleMeeting() { meetings.toggle() }

    @objc func togglePause() {
        keys.pausedUntil = keys.isPaused ? nil : Date().addingTimeInterval(3600)
    }

    /// Red mic while dictating, a red record symbol while a meeting records.
    private func refreshIcon() {
        let listening = dictation.state == .listening
        let meeting = meetings.phase == .recording
        let img = NSImage(systemSymbolName: listening ? "mic.fill" : meeting ? "record.circle" : "mic", accessibilityDescription: "VoiceType")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = listening || meeting ? .systemRed : nil
    }

    // MARK: windows

    /// The most important thing still missing, if any.
    var setupProblem: String? {
        if !(models.isReady(.vad) && (models.isReady(.moonshine) || models.isReady(.whisper))) { return "Speech models aren’t imported yet" }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return "Microphone access is needed" }
        if TriggerKey.current != .optionSpace && !KeyMonitor.hasInputMonitoring { return "Input Monitoring is needed for the \(TriggerKey.current.title) key" }
        if !Inserter.isTrusted { return "Allow Accessibility so VoiceType can paste for you" }
        return nil
    }

    var isPaused: Bool { keys.isPaused }

    /// Brings `w` up on the Space you're looking at, including over a full-screen app, instead of
    /// switching back to the desktop the window was first opened on (or, with "switch to a Space with
    /// open windows" off, opening it out of sight there). Its green button still gives it a full-screen
    /// Space of its own (`.fullScreenAuxiliary` would stop that).
    private func showOnCurrentSpace(_ w: NSWindow) {
        w.collectionBehavior.insert([.moveToActiveSpace, .fullScreenPrimary])
        w.sharingType = captureHidden ? .none : .readOnly
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Home, History, Dictionary and Styles, with the tabs in the toolbar.
    func showMainWindow(_ section: MainModel.Section? = nil) {
        if let section { mainModel.section = section }
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "VoiceType"
            w.contentViewController = NSHostingController(rootView: MainView(app: self, model: mainModel))
            w.setContentSize(NSSize(width: 760, height: 620))
            mainToolbar.attach(to: w)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("VoiceTypeMainV2") // V2: the redesigned, smaller window
            mainWindow = w
        }
        mainToolbar.sync()
        mainModel.refresh += 1
        mainWindow.map(showOnCurrentSpace)
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.contentViewController = NSHostingController(rootView: SettingsPane(app: self, model: mainModel, history: history))
            w.setContentSize(NSSize(width: 560, height: 620))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("VoiceTypeSettings")
            settingsWindow = w
        }
        mainModel.refresh += 1
        settingsWindow.map(showOnCurrentSpace)
    }

    /// Opens setup at `step`; without one, after setup was finished, at the first thing still missing
    /// ("Fix" and "Run setup again" land where they're needed).
    func showOnboarding(at step: OnboardingModel.Step? = nil) {
        if let step {
            onboardingModel.step = step
        } else if UserDefaults.standard.bool(forKey: Key.onboardingDone) {
            let needed: [OnboardingModel.Step] = [.microphone, .typing, .key, .models]
            onboardingModel.step = needed.first { !$0.isDone(self) } ?? .languages
        }
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Set up VoiceType"
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: OnboardingView(app: self, model: onboardingModel))
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        onboardingModel.refresh += 1
        onboardingWindow.map(showOnCurrentSpace)
    }

    /// Third-party notices shipped in the app bundle (Contents/Resources/THIRD_PARTY_NOTICES.txt).
    func showLicenses() {
        if licensesWindow == nil {
            let text = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? "THIRD_PARTY_NOTICES.txt is missing from this build. Build with scripts/build-dmg.sh to include it."
            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textContainerInset = NSSize(width: 12, height: 12)
            tv.string = text
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Open-source licences"
            w.contentView = scroll
            w.isReleasedWhenClosed = false
            w.center()
            licensesWindow = w
        }
        licensesWindow.map(showOnCurrentSpace)
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Key.onboardingDone)
        onboardingModel.step = .languages
        onboardingWindow?.close()
        showMainWindow(.history)
    }

    /// Opens the speech model's download in the user's browser. VoiceType itself has no network
    /// access (App Sandbox, no network entitlement); the browser does the download.
    func downloadModel() {
        NSWorkspace.shared.open(KnownModels.recommended.url)
    }

    func importModels(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose \(KnownModels.recommended.fileName) (in Downloads), or a models folder"
        if let home = getpwuid(getuid())?.pointee.pw_dir { // the real Downloads, not the sandbox container's
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        completion("Checking and copying the model…")
        speech.release()
        DispatchQueue.global(qos: .userInitiated).async {
            let report = self.models.importItem(url)
            DispatchQueue.main.async {
                completion(report)
                self.dictation.warmUp()
            }
        }
    }
}

extension FlowBar {
    /// Notice with an action button.
    func notice(_ text: String, action: String, onAction: @escaping () -> Void) {
        model.onNoticeAction = onAction
        notice(text, action: action)
    }
}
