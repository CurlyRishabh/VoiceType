import Foundation

/// Names on screen as spelling hints for the speech engine: who you're messaging (the window
/// title), names in the conversation or document you're dictating into. Whisper spells a name it
/// is shown far more often right ("Kritant", not "Crittand"). Only likely names are kept:
/// capitalised words that aren't ordinary vocabulary, and words with a capital inside ("VoiceType").
public enum ScreenNames {
    public static let maxNames = 30

    /// `sources` most useful first (the window title, the text being typed in, the rest of the
    /// window). Each name once, in that order, more frequent first within a source.
    /// At most `maxChecks` spell-checker questions (each one ~0.7 ms on the main thread).
    public static func extract(_ sources: [String], isWord: (String) -> Bool, limit: Int = maxNames, maxChecks: Int = 150) -> [String] {
        var found: [String: (word: String, source: Int, count: Int, order: Int)] = [:]
        var order = 0
        for (i, text) in sources.enumerated() {
            for w in words(text) where looksLikeName(w) {
                let key = w.lowercased()
                if var f = found[key] {
                    f.count += 1
                    found[key] = f
                } else if found.count < 600 {
                    found[key] = (w, i, 1, order)
                    order += 1
                }
            }
        }
        let ranked = found.values.sorted {
            ($0.source, -$0.count, $0.order) < ($1.source, -$1.count, $1.order)
        }
        var out: [String] = [], checks = 0
        for f in ranked where out.count < limit {
            let w = f.word
            if w.dropFirst().contains(where: \.isUppercase) { out.append(w); continue }
            guard checks < maxChecks else { continue }
            checks += 1
            if !isWord(w.lowercased()) { out.append(w) }
        }
        return out
    }

    /// Words with their possessive and edge apostrophes removed ("Rishabh's" → "Rishabh").
    static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0 == "'" || $0 == "’") }.map { s -> String in
            var w = String(s)
            for tail in ["'s", "’s"] where w.hasSuffix(tail) { w.removeLast(2) }
            return w.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        }
    }

    /// Capitalised or with a capital inside, 3+ letters, not all capitals (acronyms: Whisper knows them).
    static func looksLikeName(_ w: String) -> Bool {
        guard w.count >= 3, w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        guard w.contains(where: \.isLowercase) else { return false }
        // Contractions ("I’ve", "Don't"), not names like "O'Brien".
        if let a = w.lastIndex(where: { $0 == "'" || $0 == "’" }),
           ["ve", "ll", "re", "d", "t", "m"].contains(w[w.index(after: a)...].lowercased()) { return false }
        return w.first?.isUppercase == true || w.dropFirst().contains(where: \.isUppercase)
    }
}
