import Foundation

/// Learns Dictionary entries from the fixes you make to dictated text (like Wispr Flow): VoiceType
/// pasted `typed` between `before` and `after` in a text field; a little later the field reads
/// `now`. Words of the dictation that were replaced by a similar spelling ("get hub" → "GitHub",
/// "Rishab" → "Rishabh", "kubernetes" → "Kubernetes") become entries. Rewrites, additions and
/// deletions are not corrections and teach nothing.
public enum CorrectionLearner {
    /// At most this many words on either side of one fix.
    public static let maxRun = 3
    /// The edited dictation may grow or shrink by this many words and still be compared.
    public static let maxDrift = 4

    /// `isWord`: whether a word is ordinary vocabulary (the app asks the system spell checker).
    /// Changing one real word into another is editing, not a misheard name, and is never learned.
    public static func corrections(typed: String, before: String, after: String, now: String,
                                   known: PersonalDictionary = .empty,
                                   isWord: (String) -> Bool = { _ in false }) -> [PersonalDictionary.Entry] {
        // What is left of the dictation: the field minus the untouched text around it.
        guard now.count >= before.count, now.hasPrefix(before) else { return [] }
        var middle = String(now.dropFirst(before.count))
        if !after.isEmpty {
            guard middle.hasSuffix(after) else { return [] }
            middle = String(middle.dropLast(after.count))
        }
        guard middle != typed else { return [] }
        let a = words(typed), b = words(middle)
        guard !a.isEmpty, !b.isEmpty, abs(a.count - b.count) <= maxDrift else { return [] }

        var out: [PersonalDictionary.Entry] = []
        for (old, new) in substitutions(a, b) {
            guard old.count <= maxRun, new.count <= maxRun else { continue }
            let from = old.joined(separator: " "), to = new.joined(separator: " ")
            guard from != to, similar(from, to), to.contains(where: \.isLetter),
                  isRespelling(old, new, isWord: isWord) else { continue }
            if known.entries.contains(where: { $0.from.lowercased() == from.lowercased() && $0.to == to }) { continue }
            out.append(.init(from, to))
        }
        return Array(out.prefix(3))
    }

    /// Where a paste of `typed` landed, from the field's text before the paste (`was`) and after it
    /// (`now`): the text both share at the start and at the end was there already, what's between is the
    /// paste. The cursor isn't trusted for this: Chromium apps (Slack, T3 Code, VS Code) report it one
    /// character short for each line break above it, and an empty rich-text box reads as a lone line
    /// break that is gone once there is text. Nil until that middle is `typed` (spacing aside), e.g.
    /// while the paste hasn't landed.
    public static func locate(_ typed: String, was: String, now: String) -> (before: String, middle: String, after: String)? {
        let old = Array(was), new = Array(now)
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < min(old.count, new.count) - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let middle = String(new[p..<(new.count - s)])
        guard spaced(middle) == spaced(typed), middle.contains(where: { !$0.isWhitespace }) else { return nil }
        return (String(new[..<p]), middle, String(new[(new.count - s)...]))
    }

    /// Runs of spaces and line breaks as one space, none at the ends.
    private static func spaced(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether the field still holds the dictation between the text that was around it. Not when a
    /// chat box was sent or cleared (an empty rich-text box reads as a line break), or the text around
    /// it changed.
    public static func dictationStillThere(_ value: String, before: String, after: String) -> Bool {
        value.count > before.count + after.count && value.hasPrefix(before) && value.hasSuffix(after)
            && value.dropFirst(before.count).dropLast(after.count).contains { !$0.isWhitespace }
    }

    /// Another dictation into the same field: what VoiceType typed since the first one's `before`,
    /// i.e. the earlier dictations (with any fixes already made) plus `typed`. Nil if the text
    /// before the first dictation changed.
    public static func joinDictations(before: String, newBefore: String, typed: String) -> String? {
        guard newBefore.hasPrefix(before) else { return nil }
        return String(newBefore.dropFirst(before.count)) + typed
    }

    /// A misheard word fixed, not an edit: joined/split spelling ("get hub" → "GitHub"), a
    /// capitalised name or product ("kubernetes" → "Kubernetes", "iphone" → "iPhone"), or a new
    /// spelling of something that isn't ordinary vocabulary ("Rishab" → "Rishabh"). Not: sentence
    /// capitals ("the" → "The"), grammar ("fix" → "fixes"), or swapping real words ("affect" → "effect").
    static func isRespelling(_ old: [String], _ new: [String], isWord: (String) -> Bool) -> Bool {
        let from = old.joined(separator: " "), to = new.joined(separator: " ")
        let f = from.lowercased(), t = to.lowercased()
        let sameLetters = f.filter { !$0.isWhitespace } == t.filter { !$0.isWhitespace }
        if sameLetters && old.count != new.count { return true } // joined or split
        if f == t { // capitals only
            let inner = new.contains { $0.dropFirst().contains(where: \.isUppercase) } // GitHub, iPhone, McDonald
            return inner || !old.allSatisfy { isWord($0.lowercased()) }
        }
        // A word with a chunk stuck on or cut off ("Shashi" → "ShashiSasi" when the new word was typed
        // next to the old one): an unfinished edit, not a spelling.
        let (short, long) = f.count <= t.count ? (f, t) : (t, f)
        if long.count - short.count >= 3, long.hasPrefix(short) || long.hasSuffix(short) { return false }
        // Cut short ("Rishab" → "Rish"): a word being retyped, caught halfway.
        if f.count > t.count, f.hasPrefix(t) { return false }
        // A word plus or minus a grammatical ending ("fix" → "fixes", "walked" → "walk").
        let endings = ["s", "es", "ed", "d", "ing", "er", "ly", "'s", "’s"]
        if endings.contains(where: { t == f + $0 || f == t + $0 }) { return false }
        // In lower case: the macOS spell checker accepts almost any capitalised name ("Shashi",
        // "Sasi", "Rishab"), so asking as written would stop every name from being learned.
        let oldReal = old.allSatisfy { isWord($0.lowercased()) }, newReal = new.allSatisfy { isWord($0.lowercased()) }
        return !(oldReal && newReal)
    }

    /// Words with their edge punctuation removed ("GitHub," → "GitHub").
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// Replaced runs between two word lists (from a word-level LCS); pure insertions and deletions are dropped.
    static func substitutions(_ a: [String], _ b: [String]) -> [([String], [String])] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [([String], [String])] = []
        var i = 0, j = 0
        var oldRun: [String] = [], newRun: [String] = []
        func close() {
            if !oldRun.isEmpty && !newRun.isEmpty { out.append((oldRun, newRun)) }
            oldRun = []; newRun = []
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close(); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                newRun.append(b[j]); j += 1
            } else {
                oldRun.append(a[i]); i += 1
            }
        }
        close()
        return out
    }

    /// A respelling, not a different word: same letters ignoring case and spaces, or a small edit.
    static func similar(_ from: String, _ to: String) -> Bool {
        let x = Array(from.lowercased().filter { !$0.isWhitespace }), y = Array(to.lowercased().filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true } // capitals or spacing only
        guard min(x.count, y.count) >= 3 else { return false } // "a" → "the" is an edit, not a name
        let d = distance(x, y)
        return Double(d) <= max(1, Double(max(x.count, y.count)) * 0.4) && x.first == y.first || d <= 1
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
