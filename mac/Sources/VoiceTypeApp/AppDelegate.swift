import AppKit
import SwiftUI
import VoiceTypeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let models = ModelStore()
    let history = HistoryStore()
    let polisher = AppleIntelligencePolisher()
    lazy var speech = SpeechHost(modelsRoot: models.root)
    lazy var dictation = Dictation(models: models, speech: speech, polisher: polisher, history: history)

    private var statusItem: NSStatusItem!
    private let hotKey = HotKey()
    private let hud = HUD()
    private var settingsWindow: NSWindow?
    private var pressedAt: Date?
    private var holdTimer: Timer?
    private var startedByThisPress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        buildMenu()

        dictation.onState = { [weak self] s in self?.render(s) }
        dictation.onLevel = { [weak self] in self?.hud.level($0) }
        dictation.onMessage = { [weak self] in self?.hud.status($0, autoHide: 2.5) }
        dictation.onResult = { [weak self] r in
            guard let self else { return }
            switch Inserter.insert(r.text) {
            case .pasted: self.hud.hide()
            case .copiedOnly: self.hud.status("Copied — press ⌘V (allow Accessibility for auto-paste)", autoHide: 4)
            }
        }

        hotKey.onPress = { [weak self] in self?.hotKeyDown() }
        hotKey.onRelease = { [weak self] in self?.hotKeyUp() }
        registerHotKey()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }

        dictation.warmUp()
        if !models.isReady(.vad) || !(models.isReady(.moonshine) || models.isReady(.whisper)) || !Inserter.isTrusted {
            openSettings()
        }
    }

    // MARK: hot key: tap = toggle (auto-stops on silence), hold = push-to-talk

    private var currentPreset = -1
    private func registerHotKey() {
        let i = min(max(UserDefaults.standard.integer(forKey: Key.hotkey), 0), HotKey.presets.count - 1)
        guard i != currentPreset else { return }
        currentPreset = i
        hotKey.register(HotKey.presets[i])
        buildMenu()
    }

    private func hotKeyDown() {
        guard pressedAt == nil else { return } // key repeat
        pressedAt = Date()
        switch dictation.state {
        case .idle:
            dictation.start(autoStop: true)
            startedByThisPress = dictation.state == .listening
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                self?.dictation.disableAutoStop() // still held: it's push-to-talk
            }
        case .listening:
            startedByThisPress = false
            dictation.stop()
        default:
            startedByThisPress = false
        }
    }

    private func hotKeyUp() {
        holdTimer?.invalidate()
        defer { pressedAt = nil; startedByThisPress = false }
        guard let pressedAt, startedByThisPress else { return }
        if Date().timeIntervalSince(pressedAt) >= 0.35 { dictation.stop() } // released after a hold
    }

    // MARK: UI

    private func render(_ s: Dictation.State) {
        setIcon(s)
        switch s {
        case .listening: hud.listening()
        case .transcribing: hud.status("Transcribing…")
        case .polishing: hud.status("Polishing…")
        case .idle: break
        }
        buildMenu()
    }

    private func setIcon(_ s: Dictation.State) {
        let name: String
        switch s {
        case .idle: name = "mic"
        case .listening: name = "mic.fill"
        case .transcribing, .polishing: name = "ellipsis.circle"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceType")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = s == .listening ? .systemRed : nil
    }

    private func buildMenu() {
        let menu = NSMenu()
        let preset = HotKey.presets[max(currentPreset, 0)].title
        let toggle = NSMenuItem(title: dictation.isRecording ? "Stop dictation" : "Start dictation (\(preset))",
                                action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "Offline: sandboxed, no network access", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)
        menu.addItem(NSMenuItem(title: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleDictation() {
        if dictation.isRecording { dictation.stop() } else { dictation.start(autoStop: true) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(app: self)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "VoiceType"
            w.contentViewController = NSHostingController(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
