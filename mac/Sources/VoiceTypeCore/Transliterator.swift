import Foundation

/// Devanagari -> casual Latin ("Hinglish") with Hindi schwa deletion. Port of the Android version.
public enum Transliterator {

    public static func containsDevanagari(_ text: String) -> Bool { text.utf16.contains { $0 >= 0x0900 && $0 <= 0x097F } }

    public static func toLatin(_ text: String) -> String {
        guard containsDevanagari(text) else { return text }
        let u = Array(text.utf16)
        var out = ""
        var i = 0
        while i < u.count {
            if isWordChar(u[i]) {
                let start = i
                while i < u.count, isWordChar(u[i]) { i += 1 }
                out += word(Array(u[start..<i]))
            } else {
                if u[i] == 0x0964 || u[i] == 0x0965 { out += "." } else { out += String(utf16CodeUnits: [u[i]], count: 1) }
                i += 1
            }
        }
        return out
    }

    private enum Kind { case consonant, vowel, nasal, visarga, other }

    private final class Unit {
        let kind: Kind
        var latin: String
        var vowel: String?
        var schwa = false
        var long = false
        init(_ kind: Kind, _ latin: String, _ vowel: String? = nil) { self.kind = kind; self.latin = latin; self.vowel = vowel }
        var hasVowel: Bool { kind == .vowel || (kind == .consonant && vowel != nil) }
    }

    private static func word(_ w: [unichar]) -> String {
        let units = parse(w)
        deleteSchwas(units)
        return render(units)
    }

    private static func parse(_ w: [unichar]) -> [Unit] {
        var units: [Unit] = []
        var i = 0
        while i < w.count {
            let c = w[i]
            if let latin = consonants[c] {
                var l = latin
                if i + 1 < w.count, w[i + 1] == nukta {
                    l = nuktaForms[c] ?? l
                    i += 1
                }
                let u = Unit(.consonant, l, "a"); u.schwa = true
                units.append(u)
            } else if c == nukta || c == 0x200C || c == 0x200D || c == avagraha {
                // ignore
            } else if c == halant {
                if let last = units.last, last.kind == .consonant { last.vowel = nil; last.schwa = false }
            } else if let m = matras[c] {
                if let last = units.last, last.kind == .consonant {
                    last.vowel = m; last.schwa = false; last.long = longMatras.contains(c)
                }
            } else if let v = vowels[c] {
                units.append(Unit(.vowel, v))
            } else if c == anusvara || c == chandrabindu {
                units.append(Unit(.nasal, "n"))
            } else if c == visarga {
                units.append(Unit(.visarga, "h"))
            } else if c >= 0x0966 && c <= 0x096F {
                units.append(Unit(.other, String(c - 0x0966)))
            } else if c == 0x0950 {
                units.append(Unit(.other, "om"))
            } else {
                units.append(Unit(.other, ""))
            }
            i += 1
        }
        return units
    }

    private static func deleteSchwas(_ units: [Unit]) {
        guard let lastIdx = units.lastIndex(where: { $0.kind == .consonant || $0.kind == .vowel }) else { return }
        let syllables = units.filter { $0.kind == .consonant || $0.kind == .vowel }.count
        let last = units[lastIdx]
        if last.kind == .consonant && last.schwa && syllables > 1 {
            let prev = lastIdx > 0 ? units[lastIdx - 1] : nil
            let afterConjunct = prev != nil && prev!.kind == .consonant && prev!.vowel == nil
            if !(afterConjunct && ["y", "r", "v"].contains(last.latin)) { last.vowel = nil }
        }
        var i = lastIdx - 1
        while i >= 1 {
            let u = units[i]
            if u.kind == .consonant, u.schwa, u.vowel != nil, i + 1 < units.count {
                let prev = units[i - 1], next = units[i + 1]
                if prev.hasVowel && next.kind == .consonant && next.vowel != nil { u.vowel = nil }
            }
            i -= 1
        }
    }

    private static func render(_ units: [Unit]) -> String {
        let lastIdx = units.lastIndex(where: { $0.kind == .consonant || $0.kind == .vowel }) ?? -1
        var s = ""
        for (i, u) in units.enumerated() {
            switch u.kind {
            case .consonant:
                s += u.latin
                var v = u.vowel ?? ""
                let nasalFollows = i + 1 < units.count && units[i + 1].kind == .nasal
                if i == lastIdx && u.long && !nasalFollows {
                    v = shortFinal[v] ?? v
                } else if i == lastIdx && u.long && nasalFollows && v == "ee" {
                    v = "i"
                }
                if v == "e" && nasalFollows && i == lastIdx { v = "ei" }
                s += v
            case .nasal:
                let next = i + 1 < units.count ? units[i + 1] : nil
                let labial = next?.kind == .consonant && ["p", "b", "m"].contains(next!.latin.first.map(String.init) ?? "")
                s += labial ? "m" : "n"
            default:
                s += u.latin
            }
        }
        return s
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x0900 && c <= 0x097F && c != 0x0964 && c != 0x0965) || c == 0x200C || c == 0x200D
    }

    private static let halant: unichar = 0x094D, nukta: unichar = 0x093C, anusvara: unichar = 0x0902
    private static let chandrabindu: unichar = 0x0901, visarga: unichar = 0x0903, avagraha: unichar = 0x093D

    private static func table(_ pairs: [(String, String)]) -> [unichar: String] {
        Dictionary(uniqueKeysWithValues: pairs.map { (Array($0.0.utf16)[0], $0.1) })
    }

    private static let consonants = table([
        ("क", "k"), ("ख", "kh"), ("ग", "g"), ("घ", "gh"), ("ङ", "n"),
        ("च", "ch"), ("छ", "chh"), ("ज", "j"), ("झ", "jh"), ("ञ", "n"),
        ("ट", "t"), ("ठ", "th"), ("ड", "d"), ("ढ", "dh"), ("ण", "n"),
        ("त", "t"), ("थ", "th"), ("द", "d"), ("ध", "dh"), ("न", "n"),
        ("प", "p"), ("फ", "ph"), ("ब", "b"), ("भ", "bh"), ("म", "m"),
        ("य", "y"), ("र", "r"), ("ल", "l"), ("ळ", "l"), ("व", "v"),
        ("श", "sh"), ("ष", "sh"), ("स", "s"), ("ह", "h"),
        ("\u{0958}", "q"), ("\u{0959}", "kh"), ("\u{095A}", "g"), ("\u{095B}", "z"),
        ("\u{095C}", "r"), ("\u{095D}", "rh"), ("\u{095E}", "f"), ("\u{095F}", "y"),
    ])
    private static let nuktaForms = table([("क", "q"), ("ख", "kh"), ("ग", "g"), ("ज", "z"), ("ड", "r"), ("ढ", "rh"), ("फ", "f")])
    private static let vowels = table([
        ("अ", "a"), ("आ", "aa"), ("इ", "i"), ("ई", "ee"), ("उ", "u"), ("ऊ", "oo"), ("ऋ", "ri"),
        ("ए", "e"), ("ऐ", "ai"), ("ओ", "o"), ("औ", "au"), ("ऑ", "o"), ("ऍ", "e"),
    ])
    private static let matras = table([
        ("\u{093E}", "aa"), ("\u{093F}", "i"), ("\u{0940}", "ee"), ("\u{0941}", "u"), ("\u{0942}", "oo"), ("\u{0943}", "ri"),
        ("\u{0947}", "e"), ("\u{0948}", "ai"), ("\u{094B}", "o"), ("\u{094C}", "au"), ("\u{0949}", "o"), ("\u{0945}", "e"),
    ])
    private static let longMatras: Set<unichar> = [0x093E, 0x0940, 0x0942]
    private static let shortFinal = ["aa": "a", "ee": "i", "oo": "u"]
}

/// Joins dictated text into existing text with natural spacing. Port of the Android `TextJoin`.
public enum TextJoin {
    private static let sentenceEnd: Set<Character> = [".", "!", "?", "\n", "।"]
    private static let noSpaceBefore: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "…", "।"]

    public static func startsSentence(_ before: String?) -> Bool {
        guard let before, !before.isEmpty else { return true }
        if before.last == "\n" { return true }
        let t = before.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        return t.isEmpty || sentenceEnd.contains(t.last!)
    }

    public static func endsSentence(_ after: String?) -> Bool {
        guard let after, !after.isEmpty else { return true }
        let t = after.replacingOccurrences(of: "^[ \\t]+", with: "", options: .regularExpression)
        return t.isEmpty || t.first == "\n"
    }

    public static func pad(_ insert: String, before: String?, after: String?) -> String {
        guard let first = insert.first, let last = insert.last else { return insert }
        var s = insert
        if let b = before?.last, !b.isWhitespace, !first.isWhitespace, !noSpaceBefore.contains(first) { s = " " + s }
        if let a = after?.first, !a.isWhitespace, !noSpaceBefore.contains(a), !last.isWhitespace { s += " " }
        return s
    }
}
