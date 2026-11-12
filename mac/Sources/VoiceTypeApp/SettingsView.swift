import AppKit
import AVFoundation
import SwiftUI
import VoiceTypeCore

/// View state holder (used instead of @State, whose macro plugin isn't in the Command Line Tools).
final class ViewState: ObservableObject {
    @Published var refresh = 0
    @Published var importReport = ""
    @Published var from = ""
    @Published var to = ""
    @Published var entries: [PersonalDictionary.Entry] = AppSettings.dictionary.entries
}

struct SettingsView: View {
    let app: AppDelegate

    var body: some View {
        TabView {
            SetupTab(app: app).tabItem { Label("Setup", systemImage: "checklist") }
            GeneralTab().tabItem { Label("Dictation", systemImage: "mic") }
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab(history: app.history).tabItem { Label("History", systemImage: "clock") }
            DebugTab(app: app).tabItem { Label("Debug", systemImage: "gauge") }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 480)
    }
}

// MARK: - Setup (permissions + models)

struct SetupTab: View {
    let app: AppDelegate
    @StateObject private var vs = ViewState()

    var body: some View {
        let _ = vs.refresh
        Form {
            Section("Permissions") {
                row("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    "Needed to hear you. Audio stays in memory and is discarded after transcription.") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { vs.refresh += 1 } }
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
                row("Accessibility (auto-paste)", Inserter.isTrusted,
                    "Lets VoiceType press ⌘V for you in the app you're typing in, and see the text around the cursor for spacing/capitalisation. Without it, text is copied and you paste yourself.") {
                    Inserter.requestTrust()
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            }
            Section("Models (copied into the app; nothing is downloaded)") {
                ForEach(ModelSlot.allCases, id: \.self) { slot in
                    HStack {
                        Image(systemName: app.models.isReady(slot) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(app.models.isReady(slot) ? .green : .secondary)
                        Text(slot.title)
                        Spacer()
                        Text(app.models.isReady(slot) ? ByteCountFormatter.string(fromByteCount: app.models.size(slot), countStyle: .file) : "missing")
                            .foregroundStyle(.secondary)
                        if !app.models.files(slot).isEmpty {
                            Button("Remove") { app.speech.release(); app.models.clear(slot); vs.refresh += 1 }
                        }
                    }
                }
                HStack {
                    Button("Import models folder…") { importModels() }
                    Text("Choose the `models` folder (with vad/, moonshine/, whisper/ inside), e.g. voiceapk/models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !vs.importReport.isEmpty { Text(vs.importReport).font(.caption).textSelection(.enabled) }
            }
            Section("AI polish") {
                Text(app.polisher.statusText).foregroundStyle(app.polisher.isReady ? .green : .secondary)
            }
            Section {
                Button("Re-check") { vs.refresh += 1 }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in vs.refresh += 1 }
    }

    private func row(_ title: String, _ ok: Bool, _ detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Allow…", action: action) }
        }
    }

    private func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }

    private func importModels() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the models folder (vad, moonshine, whisper inside) or one model's folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vs.importReport = "Importing…"
        app.speech.release()
        DispatchQueue.global(qos: .userInitiated).async {
            let report = app.models.importFolder(url)
            DispatchQueue.main.async {
                vs.importReport = report
                vs.refresh += 1
                app.dictation.warmUp()
            }
        }
    }
}

// MARK: - Dictation settings

struct GeneralTab: View {
    @AppStorage(Key.language) var language = "en"
    @AppStorage(Key.englishEngine) var engine = EngineKind.fastEnglish.rawValue
    @AppStorage(Key.script) var script = "latin"
    @AppStorage(Key.silenceMs) var silence = 1500
    @AppStorage(Key.hotkey) var hotkey = 0
    @AppStorage(Key.fillers) var fillers = true
    @AppStorage(Key.corrections) var corrections = true
    @AppStorage(Key.commands) var commands = true
    @AppStorage(Key.capitalize) var capitalize = true
    @AppStorage(Key.finalPunct) var finalPunct = true
    @AppStorage(Key.polish) var polish = true
    @AppStorage(Key.polishStyle) var style = "casual"
    @AppStorage(Key.history) var historyOn = true
    @AppStorage(Key.keepRecordings) var keepRecordings = false
    @AppStorage(Key.showHUD) var showHUD = true

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Dictation key", selection: $hotkey) {
                    ForEach(HotKey.presets.indices, id: \.self) { Text(HotKey.presets[$0].title).tag($0) }
                }
                Text("Tap to start (stops after silence), tap again to stop. Hold for push-to-talk.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show floating level meter", isOn: $showHUD)
            }
            Section("Speech recognition") {
                Picker("Language", selection: $language) {
                    Text("English").tag("en"); Text("Hindi").tag("hi"); Text("Auto-detect (Hindi + English / Hinglish)").tag("auto")
                }
                Picker("English engine", selection: $engine) {
                    Text("Fast English (Moonshine Base)").tag(EngineKind.fastEnglish.rawValue)
                    Text("Hindi + English (Whisper small)").tag(EngineKind.hindiEnglish.rawValue)
                }.disabled(language != "en")
                Picker("Hindi output script", selection: $script) {
                    Text("Latin (Hinglish: \"kal meeting hai\")").tag("latin"); Text("Devanagari (\"कल मीटिंग है\")").tag("devanagari")
                }
                Stepper("Auto-stop after \(silence) ms of silence", value: $silence, in: 500...5000, step: 100)
            }
            Section("Clean-up rules (instant)") {
                Toggle("Remove filler words (um, uh, like, you know, matlab, haan toh)", isOn: $fillers)
                Toggle("Apply self-corrections (\"5 no wait 6\", \"I mean\", \"nahi nahi\")", isOn: $corrections)
                Toggle("Spoken commands (new line, new paragraph, comma, full stop, question mark)", isOn: $commands)
                Toggle("Auto-capitalise", isOn: $capitalize)
                Toggle("Add final punctuation", isOn: $finalPunct)
            }
            Section("AI polish (Apple on-device model, 3 s limit)") {
                Toggle("AI polish", isOn: $polish)
                Picker("Style", selection: $style) {
                    Text("Casual (chat)").tag("casual"); Text("Professional (email)").tag("professional"); Text("Notes (bullets)").tag("notes")
                }.disabled(!polish)
            }
            Section("Privacy") {
                Toggle("Save transcript history (on this Mac only)", isOn: $historyOn)
                Toggle("Keep recordings (debug, off by default)", isOn: $keepRecordings)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictionary

struct DictionaryTab: View {
    @StateObject private var vs = ViewState()

    var body: some View {
        VStack(alignment: .leading) {
            Text("When I say… write…  (applied last, even after AI polish)").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(vs.entries, id: \.self) { e in
                    HStack { Text(e.from); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(e.to).bold(); Spacer()
                        Button(role: .destructive) { save(AppSettings.dictionary.minus(e.from)) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("When I say (e.g. acme)", text: $vs.from)
                TextField("Write (e.g. Acme)", text: $vs.to)
                Button("Add") {
                    guard !vs.from.isEmpty, !vs.to.isEmpty else { return }
                    save(AppSettings.dictionary.plus(.init(vs.from, vs.to))); vs.from = ""; vs.to = ""
                }
            }
        }
    }

    private func save(_ d: PersonalDictionary) { AppSettings.dictionary = d; vs.entries = d.entries }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Stored only on this Mac. Click to copy.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear all", role: .destructive) { history.clearAll() }
            }
            List(history.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                    Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.engine)\(item.polished ? " · AI polished" : "")\(item.raw != item.text ? "\nheard: \(item.raw)" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                }
                .contextMenu { Button("Delete") { history.delete(item) } }
            }
        }
    }
}

// MARK: - Debug

struct DebugTab: View {
    let app: AppDelegate
    @StateObject private var vs = ViewState()

    var body: some View {
        let _ = vs.refresh
        VStack(alignment: .leading, spacing: 8) {
            Text("Real-time factor = decode time ÷ audio length (below 1 is faster than real time). \(EngineSpec(kind: .fastEnglish, language: "en").threads) inference threads.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Loaded: \(app.speech.loadedSpec.map { "\($0.kind.rawValue) \($0.language.isEmpty ? "auto" : $0.language)" } ?? "none") · last load \(app.speech.lastLoadMillis) ms")
            Text("AI polish: \(app.polisher.statusText)")
            Text("Network: blocked by the App Sandbox (the app has no network entitlement).")
            List(PerfLog.shared.recent) { e in
                Text("\(e.date.formatted(date: .omitted, time: .standard))  \(e.engine)  audio \(e.audioMillis) ms  decode \(e.decodeMillis) ms  RTF \(String(format: "%.3f", e.rtf))\(e.loadMillis > 0 ? "  load \(e.loadMillis) ms" : "")\(e.polishMillis >= 0 ? "  polish \(e.polishMillis) ms" : "")\(e.polishNote.map { "  [\($0)]" } ?? "")")
                    .font(.system(.caption, design: .monospaced))
            }
            Button("Refresh") { vs.refresh += 1 }
        }
    }
}
