import AppKit
import CryptoKit
import Foundation
import VoiceTypeCore

/// UserDefaults keys (stored inside the app's sandbox container; never synced or backed up by the app).
enum Key {
    static let language = "language"            // en | hi | auto
    static let englishEngine = "engine"         // fast_english | hindi_english
    static let script = "script"                // latin | devanagari
    static let translate = "translate_to_english" // type Hindi speech as English
    static let silenceMs = "silence_ms"
    static let fillers = "rule_fillers", corrections = "rule_corrections", commands = "rule_commands"
    static let capitalize = "rule_capitalize", finalPunct = "rule_final_punct"
    static let polish = "polish_enabled", polishStyle = "polish_style"
    static let hotkey = "hotkey"                // index into HotKey.presets
    static let history = "history_enabled", keepRecordings = "keep_recordings"
    static let dictionary = "dictionary"
    static let showHUD = "show_hud"
    static let sounds = "sounds_enabled"         // start/stop cues
    static let trigger = "trigger"              // fn | right_option | option_space
    static let handsFreeShortcut = "hands_free_shortcut" // ⇧⌥ Space toggles hands-free (off by default: double-tap the key)
    static let flowBarIdle = "flow_bar_idle"    // show the idle sliver (off unless turned on in Advanced)
    static let onboardingDone = "onboarding_done"
    static let onboardingStep = "onboarding_step"  // resume setup after macOS "Quit & Reopen"
    static let meetingShortcut = "meeting_shortcut"          // ⌃⌥R starts and stops a meeting recording
    static let meetingMaxMinutes = "meeting_max_minutes"     // 30 | 60 | 120 | 180
    static let meetingKeepAudio = "meeting_keep_audio"       // (old) keep audio forever; read once to migrate
    static let meetingAudioDays = "meeting_audio_days"       // AudioRetention: 0 delete now, N days, -1 keep
    static let meetingCallDetection = "meeting_call_detection" // off | ask | auto
    static let meetingSpeakers = "meeting_speakers"           // tell the other people on a call apart by voice
    static let learnCorrections = "learn_corrections"         // add words you fix after dictating to the Dictionary
    static let meetingHideFromCapture = "meeting_hide_from_capture" // flow bar + windows hidden from screen sharing while recording
    static let meetingEchoFilter = "meeting_echo_filter"     // drop my mic's echo of the others (no headphones)
    static let meetingConsentShown = "meeting_consent_shown"
    static let systemAudioState = "system_audio_state"       // what the last meeting's system audio did: ok | silent | unavailable
    static func style(_ c: AppCategory) -> String { "style_\(c.rawValue)" }
}

enum AppSettings {
    static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            Key.language: "en", Key.translate: false, Key.englishEngine: EngineKind.hindiEnglish.rawValue, Key.script: "latin",
            Key.silenceMs: 1500, Key.fillers: true, Key.corrections: true, Key.commands: true,
            Key.capitalize: true, Key.finalPunct: true, Key.polish: true, Key.polishStyle: "casual",
            Key.hotkey: 0, Key.history: true, Key.keepRecordings: false, Key.showHUD: true,
            Key.trigger: "fn", Key.flowBarIdle: false, Key.handsFreeShortcut: false, Key.sounds: true, Key.onboardingDone: false,
            Key.meetingShortcut: true, Key.meetingMaxMinutes: MeetingLimit.defaultMinutes, Key.meetingKeepAudio: false, Key.meetingCallDetection: "ask", Key.learnCorrections: true, Key.meetingSpeakers: true,
            Key.meetingHideFromCapture: true, Key.meetingEchoFilter: true, Key.meetingConsentShown: false,
            Key.style(.messages): StyleChoice.casual.rawValue, Key.style(.email): StyleChoice.formal.rawValue,
            Key.style(.notes): StyleChoice.notes.rawValue, Key.style(.other): StyleChoice.off.rawValue,
        ])
    }

    static func styleChoice(_ c: AppCategory) -> StyleChoice {
        StyleChoice(rawValue: d.string(forKey: Key.style(c)) ?? "") ?? AppStyleMap.defaultChoice(c)
    }

    static var engineSpec: EngineSpec {
        let language = d.string(forKey: Key.language) ?? "en"
        return translatingSpec(language, translate: d.bool(forKey: Key.translate)) ?? {
            switch language {
            case "hi": return EngineSpec(kind: .hindiEnglish, language: "hi")
            case "auto": return EngineSpec(kind: .hindiEnglish, language: "")
            default: return EngineSpec(kind: EngineKind(rawValue: d.string(forKey: Key.englishEngine) ?? "") ?? .hindiEnglish, language: "en")
            }
        }()
    }

    /// Translate to English = Whisper told the speech is English: it then writes English for Hindi
    /// speech too. (Whisper's own translate task does nothing on large-v3-turbo, which was never
    /// trained for it; Apple's on-device model translated better but refused harmless sentences.)
    /// nil when there is nothing to translate (English only, or the switch is off).
    static func translatingSpec(_ language: String, translate: Bool) -> EngineSpec? {
        translate && language != "en" ? EngineSpec(kind: .hindiEnglish, language: "en") : nil
    }

    /// The configured engine, but for English falls back to whichever model is actually imported
    /// (Whisper is the default; someone with only Moonshine still gets a working setup).
    static func engineSpec(_ models: ModelStore) -> EngineSpec {
        var s = engineSpec
        guard s.language == "en" else { return s }
        if s.kind == .hindiEnglish, !models.isReady(.whisper), models.isReady(.moonshine) { s.kind = .fastEnglish }
        if s.kind == .fastEnglish, !models.isReady(.moonshine), models.isReady(.whisper) { s.kind = .hindiEnglish }
        return s
    }

    /// The engine for meetings: Whisper (whisper.cpp when imported) in the language setting. Never
    /// "Translate to English": a meeting is transcribed as spoken. Only Moonshine imported: English
    /// meetings with chunk-level times. nil when no model can do it.
    /// `language`: "en", "hi" or "auto"; nil = the language setting.
    static func meetingSpec(_ models: ModelStore, language: String? = nil) -> EngineSpec? {
        let language = language ?? d.string(forKey: Key.language) ?? "en"
        if models.isReady(.whisper) { return EngineSpec(kind: .hindiEnglish, language: language == "auto" ? "" : language) }
        if language == "en", models.isReady(.moonshine) { return EngineSpec(kind: .fastEnglish, language: "en") }
        return nil
    }

    /// Days meeting audio is kept (AudioRetention). Someone who had "Keep audio" on keeps it for good.
    static var meetingAudioDays: Int {
        if let n = d.object(forKey: Key.meetingAudioDays) as? Int { return n }
        return d.bool(forKey: Key.meetingKeepAudio) ? -1 : AudioRetention.defaultDays
    }

    static var meetingKeepsAudio: Bool { AudioRetention.keeps(meetingAudioDays) }

    static var dictionary: PersonalDictionary {
        get { PersonalDictionary.parse(d.string(forKey: Key.dictionary)) }
        set { d.set(newValue.serialize(), forKey: Key.dictionary) }
    }

    /// `style` comes from the app being typed in (Styles screen); nil = instant rules only.
    static func cleanup(startsSentence: Bool, endsSentence: Bool, polishAvailable: Bool, style: PolishStyle?) -> CleanupSettings {
        var o = CleanupOptions()
        o.removeFillers = d.bool(forKey: Key.fillers)
        o.applySelfCorrections = d.bool(forKey: Key.corrections)
        o.applySpokenCommands = d.bool(forKey: Key.commands)
        o.autoCapitalize = d.bool(forKey: Key.capitalize)
        o.addFinalPunctuation = d.bool(forKey: Key.finalPunct) && endsSentence
        o.dictionary = dictionary
        o.startsSentence = startsSentence
        var s = CleanupSettings()
        s.options = o
        s.script = OutputScript(rawValue: d.string(forKey: Key.script) ?? "") ?? .latin
        s.polishEnabled = d.bool(forKey: Key.polish) && polishAvailable && style != nil
        s.polishStyle = style ?? .casual
        return s
    }
}

/// Speech models, in ONE folder shared with Homebrew: `~/Library/Application Support/VoiceType/Models`
/// (see `SharedModels`). A model the `voicetype-model` cask installed is simply there; Import copies
/// into the same folder. App updates never touch it. The small Silero VAD ships inside the app.
final class ModelStore {
    let root: URL
    private let bundledVAD: URL? = Bundle.main.resourceURL
        .flatMap { ModelLayout.vad($0.appendingPathComponent("models/vad", isDirectory: true)) }

    /// The real home folder: inside the sandbox, FileManager's home is the app's container.
    static var realHome: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where versions up to 1.0 kept models: inside the sandbox container.
    private static var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/models", isDirectory: true)
    }

    init() {
        let fm = FileManager.default
        let shared = SharedModels.folder(home: Self.realHome)
        let legacy = Self.legacyRoot
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
        if fm.isWritableFile(atPath: shared.path) {
            if !SharedModels.isSameFolder(shared, legacy) { Self.moveModels(from: legacy, to: shared) }
            root = shared
        } else {
            // The shared folder isn't reachable (a build without its sandbox exception): old behaviour.
            NSLog("VoiceType: %@ not writable, keeping models in the app container", shared.path)
            try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            root = legacy
        }
        // Keep multi-hundred-MB models out of Time Machine / backups.
        var r = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? r.setResourceValues(values)
    }

    /// One-time move of models imported into the container (1.0) to the shared folder. Same disk, so
    /// it's a rename, not a copy. Files already in the shared folder win; leftovers are removed.
    private static func moveModels(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        for slot in ModelSlot.allCases {
            let from = old.appendingPathComponent(slot.rawValue, isDirectory: true)
            let to = new.appendingPathComponent(slot.rawValue, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
            guard !files.isEmpty else { continue }
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            for file in files where !file.hasDirectoryPath {
                let dest = to.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: file); continue }
                do { try fm.moveItem(at: file, to: dest) } catch {
                    NSLog("VoiceType: could not move %@: %@", file.lastPathComponent, error.localizedDescription)
                }
            }
        }
        // Drop the old folder once it's empty (anything that failed to move stays put).
        let leftovers = (fm.enumerator(at: old, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
        if leftovers.isEmpty { try? fm.removeItem(at: old) }
    }

    func dir(_ slot: ModelSlot) -> URL { root.appendingPathComponent(slot.rawValue, isDirectory: true) }
    func isReady(_ slot: ModelSlot) -> Bool {
        if slot == .whisper, let model = ModelLayout.whisperCpp(dir(.whisper)) {
            // A known model of the wrong size is a cut-off download or copy: not usable.
            let bytes = Int64((try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if !KnownModels.hasExpectedSize(fileName: model.lastPathComponent, bytes: bytes) { return false }
        }
        return ModelLayout.isComplete(root, slot) || (slot == .vad && bundledVAD != nil)
    }
    var vadFile: URL? { ModelLayout.vad(dir(.vad)) ?? bundledVAD }
    var isVADBuiltIn: Bool { ModelLayout.vad(dir(.vad)) == nil && bundledVAD != nil }

    func files(_ slot: ModelSlot) -> [URL] {
        let imported = ((try? FileManager.default.contentsOfDirectory(at: dir(slot), includingPropertiesForKeys: [.fileSizeKey])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        if slot == .vad, imported.isEmpty, let b = bundledVAD { return [b] }
        return imported
    }

    func size(_ slot: ModelSlot) -> Int64 {
        files(slot).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear(_ slot: ModelSlot) { try? FileManager.default.removeItem(at: dir(slot)) }

    /// Imports what the user picked in the Open panel: a single model file (normally the downloaded
    /// `ggml-large-v3-turbo-q5_0.bin`) or a models folder. Returns a human-readable report.
    func importItem(_ url: URL) -> String {
        url.hasDirectoryPath ? importFolder(url) : importFile(url)
    }

    func importFile(_ file: URL) -> String {
        let fm = FileManager.default
        let name = file.lastPathComponent
        let slot: ModelSlot
        if ModelLayout.accepts(.whisper, name) && file.pathExtension.lowercased() == "bin" { slot = .whisper }
        else if name.lowercased().contains("vad") && file.pathExtension.lowercased() == "onnx" { slot = .vad }
        else { return "\(name) isn't a VoiceType model. Choose \(KnownModels.recommended.fileName) (or a models folder)." }
        if let problem = verify(file) { return problem }
        let dest = dir(slot)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        if slot == .whisper { // the newest whisper.cpp model replaces any older one
            for old in files(.whisper) where old.pathExtension.lowercased() == "bin" { try? fm.removeItem(at: old) }
        }
        let to = dest.appendingPathComponent(name)
        try? fm.removeItem(at: to)
        do { try fm.copyItem(at: file, to: to) } catch { return "\(slot.title): \(error.localizedDescription)" }
        return "\(slot.title): \(isReady(slot) ? "Ready" : "incomplete")"
    }

    /// Size + SHA-256 check for model files VoiceType knows by name.
    private func verify(_ file: URL) -> String? {
        let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return KnownModels.problem(fileName: file.lastPathComponent, bytes: bytes) { Self.sha256(file) }
    }

    private static func sha256(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Imports from a folder the user picked: either the whole `models` folder (with vad/, moonshine/,
    /// whisper/ inside) or a single model's folder. Returns a human-readable report.
    func importFolder(_ folder: URL) -> String {
        let fm = FileManager.default
        var report: [String] = []
        var sources: [(ModelSlot, URL)] = ModelSlot.allCases.compactMap { slot in
            let sub = folder.appendingPathComponent(slot.rawValue)
            return fm.fileExists(atPath: sub.path) ? (slot, sub) : nil
        }
        if sources.isEmpty {
            // A single model folder: guess the slot from its files.
            if ModelLayout.whisper(folder) != nil || ModelLayout.whisperCpp(folder) != nil { sources = [(.whisper, folder)] }
            else if ModelLayout.moonshine(folder) != nil { sources = [(.moonshine, folder)] }
            else if ModelLayout.vad(folder) != nil { sources = [(.vad, folder)] }
        }
        if sources.isEmpty { return "No model files found in \(folder.lastPathComponent). Pick the `models` folder (with vad/, moonshine/, whisper/ inside)." }
        for (slot, src) in sources {
            let dest = dir(slot)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
            var copied = 0
            for item in items where !item.hasDirectoryPath && ModelLayout.accepts(slot, item.lastPathComponent) {
                if let problem = verify(item) { report.append(problem); continue }
                let to = dest.appendingPathComponent(item.lastPathComponent)
                try? fm.removeItem(at: to)
                do { try fm.copyItem(at: item, to: to); copied += 1 } catch { report.append("\(slot.title): \(error.localizedDescription)") }
            }
            report.append("\(slot.title): \(copied) file(s) — \(isReady(slot) ? "Ready" : "incomplete")")
        }
        return report.joined(separator: "\n")
    }
}

/// Local-only transcript history (JSON in the sandbox container).
final class HistoryStore: ObservableObject {
    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        let date: Date
        let text: String
        let raw: String
        let engine: String
        let polished: Bool
        // Added with the redesign; optional so older history files still load.
        var app: String? = nil
        var style: String? = nil
        var audioMillis: Int? = nil
        var handsFree: Bool? = nil
    }

    @Published private(set) var items: [Item] = []
    private let file: URL
    private let maxItems = 500

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceType")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("history.json")
        items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: file))) ?? []
    }

    func add(_ item: Item) {
        items.insert(item, at: 0)
        items = Array(items.prefix(maxItems))
        save()
    }

    func delete(_ item: Item) { items.removeAll { $0.id == item.id }; save() }

    func clearAll() {
        items = []
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
