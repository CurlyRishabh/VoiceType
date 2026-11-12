import AppKit
import Foundation
import VoiceTypeCore

/// UserDefaults keys (stored inside the app's sandbox container; never synced or backed up by the app).
enum Key {
    static let language = "language"            // en | hi | auto
    static let englishEngine = "engine"         // fast_english | hindi_english
    static let script = "script"                // latin | devanagari
    static let silenceMs = "silence_ms"
    static let fillers = "rule_fillers", corrections = "rule_corrections", commands = "rule_commands"
    static let capitalize = "rule_capitalize", finalPunct = "rule_final_punct"
    static let polish = "polish_enabled", polishStyle = "polish_style"
    static let hotkey = "hotkey"                // index into HotKey.presets
    static let history = "history_enabled", keepRecordings = "keep_recordings"
    static let dictionary = "dictionary"
    static let showHUD = "show_hud"
}

enum AppSettings {
    static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            Key.language: "en", Key.englishEngine: EngineKind.fastEnglish.rawValue, Key.script: "latin",
            Key.silenceMs: 1500, Key.fillers: true, Key.corrections: true, Key.commands: true,
            Key.capitalize: true, Key.finalPunct: true, Key.polish: true, Key.polishStyle: "casual",
            Key.hotkey: 0, Key.history: true, Key.keepRecordings: false, Key.showHUD: true,
        ])
    }

    static var engineSpec: EngineSpec {
        switch d.string(forKey: Key.language) {
        case "hi": return EngineSpec(kind: .hindiEnglish, language: "hi")
        case "auto": return EngineSpec(kind: .hindiEnglish, language: "")
        default: return EngineSpec(kind: EngineKind(rawValue: d.string(forKey: Key.englishEngine) ?? "") ?? .fastEnglish, language: "en")
        }
    }

    static var dictionary: PersonalDictionary {
        get { PersonalDictionary.parse(d.string(forKey: Key.dictionary)) }
        set { d.set(newValue.serialize(), forKey: Key.dictionary) }
    }

    static func cleanup(startsSentence: Bool, endsSentence: Bool, polishAvailable: Bool) -> CleanupSettings {
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
        s.polishEnabled = d.bool(forKey: Key.polish) && polishAvailable
        s.polishStyle = PolishStyle(rawValue: d.string(forKey: Key.polishStyle) ?? "") ?? .casual
        return s
    }
}

/// Models copied into Application Support (inside the sandbox container) via the Open panel only.
final class ModelStore {
    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("VoiceType/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep multi-hundred-MB models out of Time Machine / backups.
        var r = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? r.setResourceValues(values)
    }

    func dir(_ slot: ModelSlot) -> URL { root.appendingPathComponent(slot.rawValue, isDirectory: true) }
    func isReady(_ slot: ModelSlot) -> Bool { ModelLayout.isComplete(root, slot) }
    var vadFile: URL? { ModelLayout.vad(dir(.vad)) }

    func files(_ slot: ModelSlot) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir(slot), includingPropertiesForKeys: [.fileSizeKey])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func size(_ slot: ModelSlot) -> Int64 {
        files(slot).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear(_ slot: ModelSlot) { try? FileManager.default.removeItem(at: dir(slot)) }

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
            if ModelLayout.whisper(folder) != nil { sources = [(.whisper, folder)] }
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
