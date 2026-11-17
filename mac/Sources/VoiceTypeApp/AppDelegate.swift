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
    private lazy var mainToolbar = MainToolbar(model: mainModel) { [weak self] in self?.showSettings() }
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var licensesWindow: NSWindow?
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

        keys.onTrigger = { [weak self] down, time in self?.send(down ? .keyDown(time) : .keyUp(time)) }
        keys.onHandsFreeKey = { [weak self] in self?.send(.handsFreeKey) }
        keys.onOtherKey = { [weak self] in self?.send(.otherKey) }
        keys.onEscape = { [weak self] in self?.send(.escape) }

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
        menu.addItem(.separator())

        let handsFree = item(dictation.isRecording ? "Finish dictation" : "Start hands-free", #selector(menuDictation))
        if KeyMonitor.handsFreeShortcutOn { // shown as a hint; the shortcut itself works everywhere
            handsFree.keyEquivalent = " "
            handsFree.keyEquivalentModifierMask = [.shift, .option]
        }
        menu.addItem(handsFree)
        menu.addItem(item(keys.isPaused ? "Resume \(TriggerKey.current.title)" : "Pause \(TriggerKey.current.title) for 1 hour", #selector(togglePause)))
        menu.addItem(.separator())
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

    @objc private func openSetup() { showOnboarding() }

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

    var isPaused: Bool { keys.isPaused }

    /// History, Dictionary and Styles, with the tabs in the toolbar.
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
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
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
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
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
        NSApp.activate(ignoringOtherApps: true)
        licensesWindow?.makeKeyAndOrderFront(nil)
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
