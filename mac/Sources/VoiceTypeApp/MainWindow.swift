import AppKit
import AVFoundation
import SwiftUI
import VoiceTypeCore

/// Sidebar navigation + shared view state (ObservableObject instead of @State: the Command Line
/// Tools toolchain has no SwiftUI macro plugin).
final class MainModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case home, dictionary, styles, history, settings
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .home: return "house"
            case .dictionary: return "character.book.closed"
            case .styles: return "pencil.and.outline"
            case .history: return "clock"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section? = .home
    @Published var refresh = 0
    @Published var importReport = ""
    @Published var from = ""
    @Published var to = ""
    @Published var entries: [PersonalDictionary.Entry] = AppSettings.dictionary.entries
    @Published var historyQuery = ""
}

struct MainView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VoiceType").font(.system(size: 17, weight: .bold))
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Offline · on this Mac").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                List(MainModel.Section.allCases, selection: $model.section) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
                .listStyle(.sidebar)
                ModelCard(app: app)
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                switch model.section ?? .home {
                case .home: HomeView(app: app, model: model, history: app.history)
                case .dictionary: DictionaryView(model: model)
                case .styles: StylesView(app: app)
                case .history: HistoryView(model: model, history: app.history)
                case .settings: SettingsPane(app: app, model: model)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

private struct ModelCard: View {
    let app: AppDelegate
    var body: some View {
        let spec = AppSettings.engineSpec
        let name: String = {
            guard spec.kind == .hindiEnglish else { return "Moonshine Base" }
            let isTurbo = app.models.files(.whisper).contains { $0.lastPathComponent.hasPrefix("turbo") }
            return isTurbo ? "Whisper turbo" : "Whisper small"
        }()
        let ready = app.models.isReady(spec.kind == .fastEnglish ? .moonshine : .whisper)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Speech model").font(.caption).foregroundColor(.secondary)
            Text(name).font(.system(size: 13, weight: .semibold))
            Text(ready ? (spec.kind == .fastEnglish ? "English · ready" : "Hindi + English · ready") : "Not imported")
                .font(.caption).foregroundColor(ready ? .secondary : .orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - Shared bits

private struct Keycap: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 8).frame(minWidth: 34, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18)))
    }
}

private struct Chip: View {
    let text: String
    var accent = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(accent ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07)))
            .foregroundColor(accent ? .accentColor : .primary)
    }
}

private func pageHeader(_ title: String, _ subtitle: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.system(size: 24, weight: .bold))
        if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Home

private struct HomeView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @ObservedObject var history: HistoryStore
    @AppStorage(Key.language) var language = "en"

    var body: some View {
        let trigger = TriggerKey.current
        let key = trigger == .optionSpace ? "⌥ Space" : (trigger == .fn ? "fn" : "right ⌥")
        let stats = UsageStats.lastSevenDays(history.items.map { .init(date: $0.date, text: $0.text, audioMillis: $0.audioMillis) })
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(greeting).font(.system(size: 24, weight: .bold))
                    Spacer()
                    Picker("Language", selection: $language) {
                        Text("English").tag("en"); Text("हिंदी").tag("hi"); Text("Auto").tag("auto")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                if let problem = app.setupProblem {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                        Text(problem).font(.system(size: 13))
                        Spacer()
                        Button("Fix") { app.showOnboarding() }
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                }
                HStack(spacing: 12) {
                    shortcut(Keycap(label: key), "Hold to talk", "Release to type it")
                    shortcut(Keycap(label: "\(key) \(key)"), "Hands-free", "Tap \(key) again to finish")
                    shortcut(Keycap(label: "esc"), "Cancel", "Nothing is typed")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Last 7 days").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 12) {
                        stat("\(stats.words.formatted())", "words dictated")
                        stat(stats.wordsPerMinute == 0 ? "–" : "\(stats.wordsPerMinute) wpm", "your speaking speed")
                        stat("\(stats.minutesSaved) min", "saved vs typing at 45 wpm")
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("All history") { model.section = .history }.buttonStyle(.link)
                    }
                    if history.items.isEmpty {
                        Text("Nothing yet. Hold \(key) anywhere and start talking.")
                            .foregroundColor(.secondary).padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(history.items.prefix(5))) { item in
                                HistoryRow(item: item)
                                if item.id != history.items.prefix(5).last?.id { Divider() }
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
                    }
                }
            }
            .padding(28)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }

    private func shortcut(_ cap: Keycap, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            cap
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 13)).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

private struct HistoryRow: View {
    let item: HistoryStore.Item
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(time).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let app = item.app { Chip(text: app) }
                    if let style = item.style { Chip(text: style, accent: true) }
                    if item.handsFree == true, let ms = item.audioMillis { Chip(text: String(format: "Hands-free · %d:%02d", ms / 60000, ms / 1000 % 60)) }
                    if item.raw != item.text { Text("heard: \(item.raw)").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            Button("Copy") { copy(item.text) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var time: String {
        Calendar.current.isDateInToday(item.date)
            ? item.date.formatted(date: .omitted, time: .shortened)
            : (Calendar.current.isDateInYesterday(item.date) ? "Yesterday" : item.date.formatted(.dateTime.day().month()))
    }
}

// MARK: - Styles

private struct StylesView: View {
    let app: AppDelegate
    @AppStorage(Key.polish) var polish = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    pageHeader("Styles", "VoiceType looks at the app you are typing in and picks how to tidy your words. Polishing runs on Apple’s on-device model; if it takes longer than 3 seconds, the instant rules are used instead.")
                    Spacer()
                    Toggle("AI polish", isOn: $polish).toggleStyle(.switch)
                }
                if !app.polisher.isReady {
                    Label(app.polisher.statusText, systemImage: "info.circle").font(.system(size: 13)).foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 14) {
                    StyleCard(category: .messages, said: "um so yeah i’ll be there at like 5 no wait 6", typed: "So yeah, I’ll be there at 6.")
                    StyleCard(category: .email, said: "hey priya thanks for this i looked at it uh two comments on pricing can we close by friday",
                              typed: "Hi Priya, thanks for this. I’ve left two comments on the pricing section. Could we close it by Friday?")
                    StyleCard(category: .notes, said: "ship the android build then import turbo on the mac and test hands free in slack",
                              typed: "- Ship the Android build\n- Import Whisper turbo on the Mac\n- Test hands-free mode in Slack")
                }
                .disabled(!polish)
                .opacity(polish ? 1 : 0.5)
                OtherAppsRow()
            }
            .padding(28)
        }
    }
}

private struct StyleCard: View {
    let category: AppCategory
    let said: String
    let typed: String
    @AppStorage var choice: String

    init(category: AppCategory, said: String, typed: String) {
        self.category = category
        self.said = said
        self.typed = typed
        _choice = AppStorage(wrappedValue: AppStyleMap.defaultChoice(category).rawValue, Key.style(category))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title).font(.system(size: 15, weight: .semibold))
                Text(category.examples).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Picker(category.title, selection: $choice) {
                ForEach(StyleChoice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("YOU SAID").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text(said).font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("VOICETYPE TYPED").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text(choice == StyleChoice.off.rawValue ? "Instant rules only." : typed)
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
    }
}

private struct OtherAppsRow: View {
    @AppStorage(Key.style(.other)) var choice = StyleChoice.off.rawValue
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppCategory.other.title).font(.system(size: 14, weight: .semibold))
                Text("\(AppCategory.other.examples). Off = instant rules only: fillers, corrections, punctuation, your dictionary.")
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            Spacer()
            Picker("Every other app", selection: $choice) {
                ForEach(StyleChoice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 280)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Dictionary

private struct DictionaryView: View {
    @ObservedObject var model: MainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader("Dictionary", "Names and words VoiceType should always spell your way. Applied last, even after AI polish.")
            HStack {
                TextField("When I say (e.g. acme)", text: $model.from)
                TextField("Write (e.g. Acme)", text: $model.to)
                Button("Add") {
                    guard !model.from.isEmpty, !model.to.isEmpty else { return }
                    save(AppSettings.dictionary.plus(.init(model.from, model.to)))
                    model.from = ""; model.to = ""
                }
                .keyboardShortcut(.defaultAction)
            }
            if model.entries.isEmpty {
                Text("No words yet.").foregroundColor(.secondary)
            }
            List {
                ForEach(model.entries, id: \.self) { e in
                    HStack {
                        Text(e.from)
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        Text(e.to).bold()
                        Spacer()
                        Button(role: .destructive) { save(AppSettings.dictionary.minus(e.from)) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Delete \(e.from)")
                    }
                }
            }
        }
        .padding(28)
    }

    private func save(_ d: PersonalDictionary) { AppSettings.dictionary = d; model.entries = d.entries }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var model: MainModel
    @ObservedObject var history: HistoryStore

    var body: some View {
        let q = model.historyQuery.lowercased()
        let items = q.isEmpty ? history.items : history.items.filter { $0.text.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                pageHeader("History", "Stored only on this Mac.")
                Spacer()
                Button("Clear all", role: .destructive) { history.clearAll() }
            }
            TextField("Search", text: $model.historyQuery).textFieldStyle(.roundedBorder)
            List(items) { item in
                HistoryRow(item: item)
                    .contextMenu { Button("Delete") { history.delete(item) } }
            }
        }
        .padding(28)
    }
}

// MARK: - Settings

private struct SettingsPane: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @AppStorage(Key.trigger) var trigger = TriggerKey.fn.rawValue
    @AppStorage(Key.language) var language = "en"
    @AppStorage(Key.englishEngine) var engine = EngineKind.fastEnglish.rawValue
    @AppStorage(Key.script) var script = "latin"
    @AppStorage(Key.fillers) var fillers = true
    @AppStorage(Key.corrections) var corrections = true
    @AppStorage(Key.commands) var commands = true
    @AppStorage(Key.capitalize) var capitalize = true
    @AppStorage(Key.finalPunct) var finalPunct = true
    @AppStorage(Key.flowBarIdle) var flowBarIdle = true
    @AppStorage(Key.history) var historyOn = true
    @AppStorage(Key.keepRecordings) var keepRecordings = false

    var body: some View {
        let _ = model.refresh
        Form {
            Section("Dictation key") {
                Picker("Key", selection: $trigger) {
                    ForEach(TriggerKey.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Text("Hold to talk · double-tap for hands-free · esc cancels.").font(.caption).foregroundColor(.secondary)
                Toggle("Show the flow bar when idle", isOn: $flowBarIdle)
            }
            Section("Permissions") {
                permission("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { model.refresh += 1 } }
                    openPrivacy("Privacy_Microphone")
                }
                permission("Accessibility (auto-paste)", Inserter.isTrusted) {
                    Inserter.requestTrust(); openPrivacy("Privacy_Accessibility")
                }
                if trigger != TriggerKey.optionSpace.rawValue {
                    permission("Input Monitoring (\(TriggerKey.current.title) key)", KeyMonitor.hasInputMonitoring) {
                        KeyMonitor.requestInputMonitoring(); openPrivacy("Privacy_ListenEvent")
                    }
                }
                if trigger == TriggerKey.fn.rawValue {
                    HStack {
                        Text("“Press fn key to” is set to Do Nothing")
                        Spacer()
                        switch FnKeySetting.isDoNothing {
                        case .some(true): Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        case .some(false): Button("Open Keyboard Settings") { FnKeySetting.openKeyboardSettings() }
                        case .none: Button("Check in Keyboard Settings") { FnKeySetting.openKeyboardSettings() }
                        }
                    }
                }
                Button("Run setup again") { app.showOnboarding() }
            }
            Section("Speech recognition") {
                Picker("English engine", selection: $engine) {
                    Text("Fast English (Moonshine Base)").tag(EngineKind.fastEnglish.rawValue)
                    Text("Hindi + English model").tag(EngineKind.hindiEnglish.rawValue)
                }.disabled(language != "en")
                Picker("Hindi output script", selection: $script) {
                    Text("Latin (Hinglish: “kal meeting hai”)").tag("latin"); Text("Devanagari (“कल मीटिंग है”)").tag("devanagari")
                }
            }
            Section("Clean-up rules (instant)") {
                Toggle("Remove filler words (um, uh, like, you know, matlab, haan toh)", isOn: $fillers)
                Toggle("Apply self-corrections (“5 no wait 6”, “I mean”, “nahi nahi”)", isOn: $corrections)
                Toggle("Spoken commands (new line, new paragraph, comma, full stop, question mark)", isOn: $commands)
                Toggle("Auto-capitalise", isOn: $capitalize)
                Toggle("Add final punctuation", isOn: $finalPunct)
            }
            Section("Models (copied into the app; nothing is downloaded)") {
                ForEach(ModelSlot.allCases, id: \.self) { slot in
                    HStack {
                        Image(systemName: app.models.isReady(slot) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(app.models.isReady(slot) ? .green : .secondary)
                        Text(slot.title)
                        Spacer()
                        Text(app.models.isReady(slot) ? ByteCountFormatter.string(fromByteCount: app.models.size(slot), countStyle: .file) : "missing")
                            .foregroundColor(.secondary)
                    }
                }
                Button("Import models folder…") { app.importModels { model.importReport = $0; model.refresh += 1 } }
                if !model.importReport.isEmpty { Text(model.importReport).font(.caption).textSelection(.enabled) }
            }
            Section("Privacy") {
                Toggle("Save transcript history (on this Mac only)", isOn: $historyOn)
                Toggle("Keep recordings (debug, off by default)", isOn: $keepRecordings)
                Text("Network: blocked by the App Sandbox. VoiceType has no network entitlement.").font(.caption).foregroundColor(.secondary)
            }
            Section("About") {
                HStack {
                    Text("VoiceType \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    Spacer()
                    Button("Open-source licences") { app.showLicenses() }
                }
                Text("Speech recognition by sherpa-onnx and ONNX Runtime. Models you import (Moonshine, Whisper, Silero VAD) are MIT-licensed.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Performance") {
                Text("Loaded: \(app.speech.loadedSpec.map { "\($0.kind.rawValue) \($0.language.isEmpty ? "auto" : $0.language)" } ?? "none") · \(EngineSpec(kind: .fastEnglish, language: "en").threads) threads · AI polish: \(app.polisher.statusText)")
                    .font(.caption)
                ForEach(PerfLog.shared.recent.prefix(8)) { e in
                    Text("\(e.date.formatted(date: .omitted, time: .standard))  \(e.engine)  audio \(e.audioMillis) ms  decode \(e.decodeMillis) ms  RTF \(String(format: "%.3f", e.rtf))\(e.polishMillis >= 0 ? "  polish \(e.polishMillis) ms" : "")\(e.polishNote.map { "  [\($0)]" } ?? "")")
                        .font(.system(.caption, design: .monospaced))
                }
                Button("Refresh") { model.refresh += 1 }
            }
        }
        .formStyle(.grouped)
        .onChange(of: trigger) { _ in app.applyTrigger() }
        .onChange(of: flowBarIdle) { _ in app.flowBar.refreshIdleVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh += 1 }
    }

    private func permission(_ title: String, _ ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundColor(ok ? .green : .orange)
            Text(title)
            Spacer()
            if !ok { Button("Allow…", action: action) }
        }
    }
}

func openPrivacy(_ anchor: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
}
