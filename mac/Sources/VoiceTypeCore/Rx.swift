import Foundation

/// Thin wrapper over NSRegularExpression (ICU syntax, UTF-16 offsets — the same semantics as
/// java.util.regex used by the Android version, so the rules port 1:1).
public struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    public init(_ pattern: String, ignoreCase: Bool = false, multiline: Bool = false) {
        var opts: NSRegularExpression.Options = []
        if ignoreCase { opts.insert(.caseInsensitive) }
        if multiline { opts.insert(.anchorsMatchLines) }
        re = try! NSRegularExpression(pattern: pattern, options: opts)
    }

    /// Template replacement ("$1" refers to group 1).
    public func replace(_ text: String, _ template: String) -> String {
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    /// Literal replacement (no "$" expansion).
    public func replaceLiteral(_ text: String, _ literal: String) -> String {
        replace(text, NSRegularExpression.escapedTemplate(for: literal))
    }

    /// Replacement computed per match. `groups[0]` is the whole match; missing groups are "".
    public func replace(_ text: String, _ transform: (_ groups: [String], _ range: NSRange) -> String) -> String {
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        let out = NSMutableString()
        var last = 0
        for m in matches {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out.append(transform(groups(m, ns), m.range))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out as String
    }

    public func firstMatch(_ text: String, from: Int = 0) -> (range: NSRange, groups: [String])? {
        let ns = text as NSString
        guard from <= ns.length,
              let m = re.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) else { return nil }
        return (m.range, groups(m, ns))
    }

    public func matches(_ text: String) -> [String] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    public func matchRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    public func containsMatch(_ text: String) -> Bool { firstMatch(text) != nil }

    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    private func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// UTF-16 helpers so substring arithmetic matches the Kotlin implementation exactly.
extension String {
    var u16len: Int { (self as NSString).length }
    func u16sub(_ from: Int, _ to: Int) -> String { (self as NSString).substring(with: NSRange(location: from, length: to - from)) }
    func u16sub(from: Int) -> String { (self as NSString).substring(from: from) }
    func u16at(_ i: Int) -> unichar { (self as NSString).character(at: i) }
}

enum TextPatterns {
    static let wordChar = "\\p{L}\\p{M}\\p{N}"
    /// Not preceded by a word character or apostrophe (Java's \b is ASCII-only; this is Unicode-aware).
    static let wbStart = "(?<![\(wordChar)'’])"
    static let wbEnd = "(?![\(wordChar)])"
    static let clauseEndChars: Set<unichar> = Set(".!?;\n।".utf16)

    static func words(_ alternatives: String) -> Rx { Rx("\(wbStart)(?:\(alternatives))\(wbEnd)", ignoreCase: true) }

    static func isWordChar(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        let p = s.properties
        return p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark || p.generalCategory == .spacingMark
    }

    static func isLetter(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isDevanagari(_ c: unichar) -> Bool { c >= 0x0900 && c <= 0x097F }
}
