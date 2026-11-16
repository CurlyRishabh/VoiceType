import Foundation

/// Word / character error rate for the real-audio benchmark (scripts/bench-asr.sh).
///
/// Both reference and hypothesis go through the same light normaliser: lower-case, punctuation
/// removed (apostrophes kept), "mister" -> "mr" etc., and English digits spelled out ("10" -> "ten").
/// It is deliberately simple, so absolute WERs run a little higher than published numbers that use
/// OpenAI's full Whisper normaliser; compare engines with each other, on the same data.
public enum ASRMetrics {
    public struct Score: Sendable, Equatable {
        public var errors = 0      // substitutions + deletions + insertions
        public var refCount = 0    // words (or characters) in the reference
        public init(errors: Int = 0, refCount: Int = 0) { self.errors = errors; self.refCount = refCount }
        public var rate: Double { refCount == 0 ? 0 : Double(errors) / Double(refCount) }
        public static func + (a: Score, b: Score) -> Score { Score(errors: a.errors + b.errors, refCount: a.refCount + b.refCount) }
    }

    public static func wer(reference: String, hypothesis: String, language: String) -> Score {
        let r = words(reference, language: language), h = words(hypothesis, language: language)
        return Score(errors: editDistance(r, h), refCount: r.count)
    }

    /// Character error rate over the normalised text without spaces (useful for Hindi, where word
    /// boundaries and spelling variants make WER harsh).
    public static func cer(reference: String, hypothesis: String, language: String) -> Score {
        let r = Array(words(reference, language: language).joined()), h = Array(words(hypothesis, language: language).joined())
        return Score(errors: editDistance(r, h), refCount: r.count)
    }

    public static func words(_ text: String, language: String) -> [String] {
        var t = text.lowercased()
        // Dashes and slashes separate words; other punctuation (and the Devanagari danda) is dropped.
        t = t.replacingOccurrences(of: "[-–—/]", with: " ", options: .regularExpression)
        t = String(t.unicodeScalars.map { s -> Character in
            if s == "'" || s == "’" { return "'" }
            return CharacterSet.alphanumerics.contains(s) ? Character(s) : " "
        })
        var out = t.split(separator: " ").map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
        if language.hasPrefix("en") {
            out = out.flatMap { w -> [String] in
                if let canonical = abbreviations[w] { return [canonical] }
                if let n = Int(w), n >= 0, n < 1_000_000 { return spellOut(n) }
                return [w]
            }
        }
        return out
    }

    /// Levenshtein distance over tokens.
    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static let abbreviations: [String: String] = [
        "mister": "mr", "missus": "mrs", "missis": "mrs", "doctor": "dr", "saint": "st",
        "okay": "ok", "o'clock": "oclock",
    ]

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                       "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// 1984 -> ["one", "thousand", "nine", "hundred", "eighty", "four"] (no "and", like LibriSpeech).
    static func spellOut(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : spellOut(n % 100)) }
        return spellOut(n / 1000) + ["thousand"] + (n % 1000 == 0 ? [] : spellOut(n % 1000))
    }
}
