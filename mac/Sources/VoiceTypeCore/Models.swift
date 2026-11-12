import Foundation

public struct PersonalDictionary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Codable, Hashable {
        public var from: String
        public var to: String
        public init(_ from: String, _ to: String) { self.from = from; self.to = to }
    }

    public let entries: [Entry]
    private let compiled: [(Rx, String)]

    public init(_ entries: [Entry]) {
        var seen = Set<String>()
        let clean = entries
            .map { Entry(Self.sanitize($0.from), Self.sanitize($0.to)) }
            .filter { !$0.from.isEmpty && !$0.to.isEmpty }
            .filter { seen.insert($0.from.lowercased()).inserted }
        self.entries = clean
        compiled = clean
            .sorted { $0.from.u16len > $1.from.u16len }
            .map { e in
                let body = e.from.split(whereSeparator: \.isWhitespace).map { Rx.escape(String($0)) }.joined(separator: "\\s+")
                return (TextPatterns.words(body), e.to)
            }
    }

    public static let empty = PersonalDictionary([])

    public var isEmpty: Bool { entries.isEmpty }

    public func apply(_ text: String) -> String {
        compiled.reduce(text) { acc, pair in pair.0.replaceLiteral(acc, pair.1) }
    }

    public func serialize() -> String { entries.map { "\($0.from)\t\($0.to)" }.joined(separator: "\n") }

    public static func parse(_ s: String?) -> PersonalDictionary {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let entries = s.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Entry? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            return parts.count == 2 ? Entry(String(parts[0]), String(parts[1])) : nil
        }
        return PersonalDictionary(entries)
    }

    public func plus(_ e: Entry) -> PersonalDictionary {
        let key = e.from.trimmingCharacters(in: .whitespaces).lowercased()
        return PersonalDictionary(entries.filter { $0.from.lowercased() != key } + [e])
    }

    public func minus(_ from: String) -> PersonalDictionary {
        PersonalDictionary(entries.filter { $0.from.lowercased() != from.lowercased() })
    }

    public static func == (a: PersonalDictionary, b: PersonalDictionary) -> Bool { a.entries == b.entries }

    private static func sanitize(_ s: String) -> String {
        Rx("[\\t\\r\\n]+").replace(s, " ").trimmingCharacters(in: .whitespaces)
    }
}

public struct CleanupOptions: Sendable, Equatable {
    public var removeFillers = true
    public var applySelfCorrections = true
    public var applySpokenCommands = true
    public var autoCapitalize = true
    public var addFinalPunctuation = true
    public var dictionary = PersonalDictionary.empty
    /// False when inserting mid-sentence, so the first word isn't force-capitalised.
    public var startsSentence = true
    public init() {}
}

public enum OutputScript: String, Sendable, CaseIterable { case latin, devanagari }
public enum PolishStyle: String, Sendable, CaseIterable { case casual, professional, notes }

public struct CleanupSettings: Sendable {
    public var options = CleanupOptions()
    public var script: OutputScript = .latin
    public var polishEnabled = false
    public var polishStyle: PolishStyle = .casual
    public init() {}
}
