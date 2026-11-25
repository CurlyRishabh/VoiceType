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

    public static func corrections(typed: String, before: String, after: String, now: String,
                                   known: PersonalDictionary = .empty) -> [PersonalDictionary.Entry] {
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
            guard from != to, similar(from, to), to.contains(where: \.isLetter) else { continue }
            if known.entries.contains(where: { $0.from.lowercased() == from.lowercased() && $0.to == to }) { continue }
            out.append(.init(from, to))
        }
        return Array(out.prefix(3))
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
