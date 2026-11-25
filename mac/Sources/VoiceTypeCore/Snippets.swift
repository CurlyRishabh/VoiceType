import Foundation

/// Snippets: say a short cue ("my calendar link") and the saved text is typed instead, exactly as
/// written. The cue is found in the cleaned-up dictation whatever its capitals or punctuation, and
/// with or without spaces inside or between words ("linked in" for "LinkedIn"). `{date}`, `{time}`
/// and `{day}` in the text are filled in when it's typed.
public struct Snippet: Codable, Equatable, Hashable, Sendable {
    public var trigger: String
    public var expansion: String
    /// Only when the cue is the whole dictation ("insert date" said on its own), not inside a sentence.
    public var alone: Bool

    public init(_ trigger: String, _ expansion: String, alone: Bool = false) {
        self.trigger = trigger
        self.expansion = expansion
        self.alone = alone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try c.decode(String.self, forKey: .trigger)
        expansion = try c.decode(String.self, forKey: .expansion)
        alone = try c.decodeIfPresent(Bool.self, forKey: .alone) ?? false
    }

    /// Ready to use from the start (removable): nothing personal in them. Said on their own only,
    /// so "insert time stamps" in a sentence stays as it is.
    public static let defaults: [Snippet] = [
        .init("insert date", "{date}", alone: true),
        .init("insert time", "{time}", alone: true),
    ]

    /// Offered as examples to fill in (your own address, link, wording).
    public static let examples: [(title: String, snippet: Snippet)] = [
        ("My email", .init("my email", "name@example.com")),
        ("Calendar link", .init("my calendar link", "https://cal.com/your-name")),
        ("Intro email", .init("intro email", "Hi, thanks for reaching out. A little about me: …")),
        ("Review prompt", .init("review prompt", "Review this change for bugs, edge cases and missing tests. List the problems by severity, each with the file and line.")),
    ]

    /// Shorter cues ("a", "ok") would turn up inside ordinary sentences.
    public static let minimumCueLetters = 4
}

public struct SnippetSet: Sendable, Equatable {
    public let snippets: [Snippet]
    /// Each cue said on its own, longest first.
    private let whole: [(Rx, String)]
    /// All cues usable inside a sentence as one pattern (longest first), group i+1 = `inline[i]`.
    private let anywhere: Rx?
    private let inline: [String]

    public init(_ snippets: [Snippet]) {
        var seen = Set<String>()
        let clean = snippets
            .map { Snippet($0.trigger.split(whereSeparator: \.isWhitespace).joined(separator: " "), $0.expansion, alone: $0.alone) }
            .filter { Self.usable($0.trigger) && !$0.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert(Self.key($0.trigger)).inserted }
        self.snippets = clean
        // Longest cue first, so "my work email" wins over "my email".
        let sorted = clean.sorted { Self.key($0.trigger).count > Self.key($1.trigger).count }
        whole = sorted.compactMap { s in
            Self.cuePattern(s.trigger).map { (Rx("^[\\s\\p{P}]*(?:\($0))[\\s\\p{P}]*$", ignoreCase: true), s.expansion) }
        }
        let inlineSnippets = sorted.filter { !$0.alone }
        let alternatives = inlineSnippets.compactMap { Self.cuePattern($0.trigger) }.map { "(\($0))" }
        inline = inlineSnippets.map(\.expansion)
        anywhere = alternatives.isEmpty ? nil
            : Rx("(?<![\(TextPatterns.wordChar)'’-])(?:\(alternatives.joined(separator: "|")))(?![\(TextPatterns.wordChar)])", ignoreCase: true)
    }

    public static let empty = SnippetSet([])
    public var isEmpty: Bool { snippets.isEmpty }

    /// The dictation with every cue replaced, and how many were. A dictation that is only a cue
    /// ("My LinkedIn.") becomes only the text, without the punctuation added around the cue. Cues
    /// are found in what you said only: one inside a snippet's text is left alone.
    public func apply(_ text: String, now: Date = Date(), locale: Locale = .current) -> (text: String, used: Int) {
        for (rx, expansion) in whole where rx.containsMatch(text) {
            return (Self.fill(expansion, now: now, locale: locale), 1)
        }
        guard let anywhere else { return (text, 0) }
        var used = 0
        let out = anywhere.replace(text) { groups, _ in
            guard let i = groups.dropFirst().firstIndex(where: { !$0.isEmpty }), i - 1 < inline.count else { return groups[0] }
            used += 1
            return Self.fill(inline[i - 1], now: now, locale: locale)
        }
        return (out, used)
    }

    public static func == (a: SnippetSet, b: SnippetSet) -> Bool { a.snippets == b.snippets }

    /// Same cue: letters and digits only, lower case ("My Linked-In" = "my linkedin").
    public static func key(_ trigger: String) -> String {
        trigger.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Long enough to be a cue (see `Snippet.minimumCueLetters`).
    public static func usable(_ trigger: String) -> Bool {
        key(trigger).count >= Snippet.minimumCueLetters && cuePattern(trigger) != nil
    }

    /// A cue as a pattern: its letters in order, with an optional space or hyphen between letters of a
    /// word and optional spaces or commas between words (speech engines split and join words), but
    /// never across a full stop. Nil for a cue with no letters or digits.
    static func cuePattern(_ trigger: String) -> String? {
        let words = trigger.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { w in
            w.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        }.filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !words.isEmpty else { return nil }
        return words.map { w in
            w.map { ch -> String in ch == "'" || ch == "’" ? "['’]?" : NSRegularExpression.escapedPattern(for: String(ch)) }
                .joined(separator: "[ -]?")
        }.joined(separator: "[\\s,;:–—-]*")
    }

    static func fill(_ expansion: String, now: Date, locale: Locale) -> String {
        guard expansion.contains("{") else { return expansion }
        func format(_ f: (DateFormatter) -> Void) -> String {
            let df = DateFormatter()
            df.locale = locale
            f(df)
            // macOS puts a narrow no-break space before AM/PM: odd in terminals and plain-text fields.
            return df.string(from: now).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        return expansion
            .replacingOccurrences(of: "{date}", with: format { $0.dateStyle = .long; $0.timeStyle = .none })
            .replacingOccurrences(of: "{time}", with: format { $0.dateStyle = .none; $0.timeStyle = .short })
            .replacingOccurrences(of: "{day}", with: format { $0.setLocalizedDateFormatFromTemplate("EEEE") })
    }
}
