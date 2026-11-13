import AppKit
import AVFoundation
import SwiftUI
import VoiceTypeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let models = ModelStore()
    let history = HistoryStore()
    let polisher = AppleIntelligencePolisher()
    lazy var speech = SpeechHost(modelsRoot: models.root)
    lazy var dictation = Dictation(models: models, speech: speech, polisher: polisher, history: history)
    let flowBar = FlowBar()

    private let keys = KeyMonitor()
    private var gesture = TriggerGesture()
    private var deadlineTimer: Timer?
    private var elapsedTimer: Timer?
    private var statusItem: NSStatusItem!
    private let mainModel = MainModel()
    private let onboardingModel = OnboardingModel()
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lastText: String?
    private var lastApp: String?

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setIcon(listening: false)

        flowBar.model.onStop = { [weak self] in self?.send(.stopButton) }
        flowBar.model.onCancel = { [weak self] in self?.send(.cancelButton) }
        flowBar.model.onOpen = { [weak self] in self?.showMainWindow() }

        keys.onTrigger = { [weak self] down in
            let now = ProcessInfo.processInfo.systemUptime
            self?.send(down ? .keyDown(now) : .keyUp(now))
        }
        keys.onOtherKey = { [weak self] in self?.send(.otherKey) }
        keys.onEscape = { [weak self] in self?.send(.escape) }

        dictation.onState = { [weak self] s in self?.dictationState(s) }
        dictation.onLevel = { [weak self] in self?.flowBar.model.push($0) }
        dictation.onMessage = { [weak self] m in self?.flowBar.notice(m, action: "Fix", onAction: { self?.showOnboarding() }) }
        dictation.onEndedByItself = { [weak self] in self?.gesture.reset(); self?.stopTimers() }
        dictation.onResult = { [weak self] r, target in self?.deliver(r.text, appName: target.appName) }

        applyTrigger()
        dictation.warmUp()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.keys.tapRunning else { return }
            self.applyTrigger() // Input Monitoring may have just been granted
        }

        if !UserDefaults.standard.bool(forKey: Key.onboardingDone) || setupProblem != nil { showOnboarding() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: trigger key -> gesture -> dictation

    func applyTrigger() {
        let ok = keys.start(TriggerKey.current)
        if !ok { NSLog("VoiceType: key listener not running yet (Input Monitoring)") }
    }

    private func send(_ event: TriggerGesture.Event) {
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
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.send(.tick(ProcessInfo.processInfo.systemUptime))
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func dictationState(_ s: Dictation.State) {
        setIcon(listening: s == .listening)
        switch s {
        case .listening:
            flowBar.set(dictation.handsFree ? .handsFree : .listening)
        case .transcribing, .polishing:
            flowBar.set(.typing)
        case .idle:
            if flowBar.model.phase != .notice { flowBar.set(.idle) }
        }
    }

    private func deliver(_ text: String, appName: String?) {
        lastText = text
        lastApp = appName
        switch Inserter.insert(text) {
        case .pasted:
            break
        case .copiedOnly:
            flowBar.notice("Copied – press ⌘V", action: "Fix") { [weak self] in self?.showOnboarding(at: .typing) }
        }
    }

    // MARK: menu bar

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: setupProblem ?? (keys.isPaused ? "Paused · offline" : "Ready · offline"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if let lastText {
            let header = NSMenuItem(title: "Last dictation\(lastApp.map { " · \($0)" } ?? "")", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let preview = NSMenuItem(title: lastText.count > 60 ? String(lastText.prefix(60)) + "…" : lastText, action: nil, keyEquivalent: "")
            preview.isEnabled = false
            menu.addItem(preview)
            menu.addItem(item("Paste again", #selector(pasteAgain)))
            menu.addItem(item("Copy", #selector(copyLast)))
            menu.addItem(.separator())
        }

        let lang = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = UserDefaults.standard.string(forKey: Key.language) ?? "en"
        for (code, title) in [("en", "English"), ("hi", "हिंदी"), ("auto", "Auto (Hindi + English)")] {
            let i = item(title, #selector(setLanguage(_:)))
            i.representedObject = code
            i.state = code == current ? .on : .off
            sub.addItem(i)
        }
        lang.submenu = sub
        menu.addItem(lang)

        let front = NSWorkspace.shared.frontmostApplication
        let category = AppStyleMap.category(bundleID: front?.bundleIdentifier)
        let style = NSMenuItem(title: "Style in \(front?.localizedName ?? "this app"): \(AppSettings.styleChoice(category).title)", action: nil, keyEquivalent: "")
        style.isEnabled = false
        menu.addItem(style)
        menu.addItem(.separator())

        menu.addItem(item(dictation.isRecording ? "Finish dictation" : "Start hands-free dictation", #selector(menuDictation)))
        menu.addItem(item("Open VoiceType", #selector(openMain), key: ","))
        menu.addItem(item(keys.isPaused ? "Resume \(TriggerKey.current.title)" : "Pause \(TriggerKey.current.title) for 1 hour", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func pasteAgain() {
        guard let lastText else { return }
        // Let the menu close and focus return to the app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.deliver(lastText, appName: self.lastApp) }
    }

    @objc private func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: Key.language)
        dictation.warmUp()
    }

    @objc private func menuDictation() {
        if dictation.isRecording { send(.stopButton) } else { gesture.startHandsFree().forEach(apply) }
    }

    @objc private func openMain() { showMainWindow() }

    @objc private func togglePause() {
        keys.pausedUntil = keys.isPaused ? nil : Date().addingTimeInterval(3600)
    }

    private func setIcon(listening: Bool) {
        let img = NSImage(systemSymbolName: listening ? "mic.fill" : "mic", accessibilityDescription: "VoiceType")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = listening ? .systemRed : nil
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

    func showMainWindow(_ section: MainModel.Section? = nil) {
        if let section { mainModel.section = section }
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "VoiceType"
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: MainView(app: self, model: mainModel))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("VoiceTypeMain")
            w.center()
            mainWindow = w
        }
        mainModel.refresh += 1
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding(at step: OnboardingModel.Step? = nil) {
        if let step { onboardingModel.step = step }
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
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Key.onboardingDone)
        onboardingWindow?.close()
        showMainWindow(.home)
    }

    func importModels(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the models folder (vad, moonshine, whisper inside) or one model’s folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        completion("Importing…")
        speech.release()
        DispatchQueue.global(qos: .userInitiated).async {
            let report = self.models.importFolder(url)
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
