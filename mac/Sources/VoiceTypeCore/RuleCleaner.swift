import Foundation

/// Stage 1 cleanup — a line-by-line port of the Android `RuleCleaner` (same rules, same tests).
public struct RuleCleaner: Sendable {
    public init() {}

    private static let S = TextPatterns.wbStart
    private static let E = TextPatterns.wbEnd

    public func clean(_ input: String, _ options: CleanupOptions = CleanupOptions()) -> String {
        var t = normalizeWhitespace(input)
        if t.isEmpty { return t }
        if options.applySpokenCommands { t = applySpokenCommands(t) }
        if options.removeFillers { t = removeFillers(t) }
        if options.applySelfCorrections { t = applySelfCorrections(t) }
        t = fixSpacingAndPunctuation(t)
        if options.autoCapitalize { t = capitalize(t, startsSentence: options.startsSentence) }
        t = options.dictionary.apply(t)
        if options.addFinalPunctuation { t = addFinalPunctuation(t) }
        return t
    }

    // MARK: whitespace

    public func normalizeWhitespace(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        t = Rx("[\\t\\u00A0\\u200B ]+").replace(t, " ")
        t = Rx(" *\n *").replace(t, "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: spoken commands

    private static let commands: [(Rx, String)] = [
        (Rx(" *,? *\(S)(?:new|next) paragraph\(E)[,.;:!?।]* *|" +
            " *,? *\(S)(?:naya|nayaa) paragraph\(E)[,.;:!?।]* *|" +
            " *,? *नया पैराग्राफ\(E)[,.;:!?।]* *", ignoreCase: true), "\n\n"),
        (Rx(" *,? *\(S)(?:new ?line|next line)\(E)[,.;:!?।]* *|" +
            " *,? *\(S)(?:nayi|nai|nyi) line\(E)[,.;:!?।]* *|" +
            " *,? *नई लाइन\(E)[,.;:!?।]* *", ignoreCase: true), "\n"),
        (Rx(" *[,.!?]? *\(S)question mark\(E)[,.?]*", ignoreCase: true), "?"),
        (Rx(" *[,.!?]? *\(S)exclamation (?:mark|point)\(E)[,.!]*", ignoreCase: true), "!"),
        (Rx(" *[,.!?]? *\(S)full stop\(E)[,.]*", ignoreCase: true), "."),
        // "period" only at the end of a line/utterance, and not after words that make it a noun.
        (Rx(" *[,.]? *(?<!(?:^|\\s)(?:a|the|this|that|each|every|trial|grace|time|waiting|notice|long|short) )" +
            "\(S)period\(E)[,.!?]*(?= *(?:\n|$))", ignoreCase: true), "."),
        (Rx(" *[,.]? *\(S)comma\(E)[,.]*", ignoreCase: true), ","),
    ]

    public func applySpokenCommands(_ text: String) -> String {
        Self.commands.reduce(text) { acc, cmd in cmd.0.replaceLiteral(acc, cmd.1) }
    }

    // MARK: fillers

    private static let alwaysFillers = TextPatterns.words("u+m+|u+h+|u+h+m+|e+r+m*|h+m+|m{2,}")
    private static let discourseMarkers = ["you know", "like", "matlab", "मतलब"]
    private static let haanToh = Rx("(^|[.!?;\\n।] *)\(S)(?:haan|han|haa|हाँ|हां) +(?:toh|to|तो)\(E),? *", ignoreCase: true)

    public func removeFillers(_ text: String) -> String {
        var t = Self.alwaysFillers.replace(text, "")
        for marker in Self.discourseMarkers { t = removeDiscourseMarker(t, marker) }
        t = Self.haanToh.replace(t) { g, _ in g[1] }
        return tidyAfterRemoval(t)
    }

    private func removeDiscourseMarker(_ text: String, _ marker: String) -> String {
        let m = marker.split(separator: " ").map { Rx.escape(String($0)) }.joined(separator: " +")
        let S = Self.S, E = Self.E
        var t = text
        t = Rx(", *\(S)\(m)\(E) *,", ignoreCase: true).replace(t, " ")
        t = Rx("(^|[.!?;\\n।] *)\(S)\(m)\(E) *, *", ignoreCase: true).replace(t) { g, _ in g[1] }
        t = Rx(", *\(S)\(m)\(E) *(?=[.!?;\\n।]|$)", ignoreCase: true).replace(t, "")
        t = Rx("\(S)\(m) +\(m)\(E)", ignoreCase: true).replace(t, "")
        return t
    }

    private func tidyAfterRemoval(_ text: String) -> String {
        var t = Rx(" {2,}").replace(text, " ")
        t = Rx(" +([,.!?;:।])").replace(t, "$1")
        t = Rx(",(?: *,)+").replace(t, ",")
        t = Rx("(^|[.!?;\\n।])( *)(?:, *)+").replace(t, "$1$2")
        t = Rx(",+([.!?;।])").replace(t, "$1")
        t = Rx(" *\n *").replace(t, "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: self-corrections

    private static let correctionMarker = Rx(
        "[,;]? *\(S)(?:" +
            "no,? +wait|wait,? +no|" +
            "actually,? +no|" +
            "sorry,? +i +mean|" +
            "i +mean|" +
            "nahi?n?,? +nahi?n?|" +
            "नहीं,? +नहीं|नही,? +नही" +
            ")\(E)[,.;]? *",
        ignoreCase: true
    )
    private static let wordSpan = Rx("[^\\s,;:]+")
    private static let notACorrectionBefore: Set<String> = ["what", "which", "that", "if"]
    private static let notACorrectionAfter: Set<String> = ["it", "that", "this", "what", "to", "well", "business"]
    private static let noWaitNouns: Set<String> = ["time", "times", "list", "lists"]

    /// "X no wait Y", "X I mean Y", "X nahi nahi Y" -> keep Y (see the Android version for details).
    public func applySelfCorrections(_ text: String) -> String {
        var t = text
        var searchFrom = 0
        var guardCount = 0
        while guardCount < 50 {
            guardCount += 1
            guard let m = Self.correctionMarker.firstMatch(t, from: searchFrom) else { break }
            let mStart = m.range.location
            let mEnd = m.range.location + m.range.length // exclusive
            var clauseStart = lastIndexOfClauseEnd(t, before: mStart - 1).map { $0 + 1 } ?? 0
            var left = t.u16sub(clauseStart, mStart)
            var leftWords = Self.wordSpan.matchRanges(left)
            let lowerMarker = m.groups[0].lowercased()
            let strongMarker = !lowerMarker.contains("mean") || lowerMarker.contains("sorry")
            // "at 5. No wait. 6": let a strong marker reach back over a recogniser-inserted full stop.
            if leftWords.isEmpty, strongMarker, clauseStart >= 2, Set(".!?।".utf16).contains(t.u16at(clauseStart - 1)) {
                let prevStart = lastIndexOfClauseEnd(t, before: clauseStart - 2).map { $0 + 1 } ?? 0
                left = t.u16sub(prevStart, clauseStart - 1)
                leftWords = Self.wordSpan.matchRanges(left)
                clauseStart = prevStart
            }
            let nextBoundary = indexOfClauseEnd(t, from: mEnd) ?? t.u16len
            let rightClause = t.u16sub(mEnd, nextBoundary)
            let rightWords = Self.wordSpan.matches(rightClause).map(norm).filter { !$0.isEmpty }

            let markerText = m.groups[0].lowercased()
            let isIMean = markerText.contains("mean")
            let prevWord = leftWords.last.map { norm((left as NSString).substring(with: $0)) }
            let firstRight = rightWords.first

            let notACorrection =
                (isIMean && prevWord != nil && Self.notACorrectionBefore.contains(prevWord!)) ||
                (isIMean && firstRight != nil && Self.notACorrectionAfter.contains(firstRight!)) ||
                (isIMean && leftWords.isEmpty && !markerText.contains(",")) ||
                (markerText.contains("wait") && firstRight != nil && Self.noWaitNouns.contains(firstRight!))
            if notACorrection {
                searchFrom = mEnd
                continue
            }
            if rightWords.isEmpty {
                t = t.u16sub(0, mStart) + t.u16sub(from: mEnd)
                searchFrom = mStart
                continue
            }
            if leftWords.isEmpty {
                var head = t.u16sub(0, mStart)
                while head.hasSuffix(" ") { head.removeLast() }
                let needsSpace = mStart > 0 && !isWhitespace(t.u16at(mStart - 1))
                t = head + (needsSpace ? " " : "") + t.u16sub(from: mEnd)
                searchFrom = clauseStart
                continue
            }

            let leftNorm = leftWords.map { norm((left as NSString).substring(with: $0)) }
            var cut = leftWords.count - 1
            for i in 0..<min(rightWords.count, 3) {
                if let p = leftNorm.lastIndex(of: rightWords[i]), p - i >= 0 {
                    cut = p - i
                    break
                }
            }
            var keptLeft = t.u16sub(clauseStart, clauseStart + leftWords[cut].location)
            while let last = keptLeft.last, last == " " || last == "," { keptLeft.removeLast() }
            let prefix = t.u16sub(0, clauseStart)
            var rest = t.u16sub(from: mEnd)
            while let first = rest.first, first == " " || first == "," { rest.removeFirst() }
            let joiner = keptLeft.isEmpty ? "" : " "
            let leadingSpace = (keptLeft.isEmpty && !prefix.isEmpty && !isWhitespace(prefix.u16at(prefix.u16len - 1))) ? " " : ""
            let head = prefix + leadingSpace + keptLeft + joiner
            t = head + rest
            searchFrom = head.u16len
        }
        return t
    }

    private func norm(_ word: String) -> String {
        let lower = word.lowercased()
        let kept = lower.utf16.filter { TextPatterns.isWordChar($0) || $0 == 0x27 }
        return String(utf16CodeUnits: kept, count: kept.count)
    }

    private func isWhitespace(_ c: unichar) -> Bool { c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D }

    private func lastIndexOfClauseEnd(_ t: String, before index: Int) -> Int? {
        var i = index
        while i >= 0 {
            if TextPatterns.clauseEndChars.contains(t.u16at(i)) { return i }
            i -= 1
        }
        return nil
    }

    private func indexOfClauseEnd(_ t: String, from: Int) -> Int? {
        var i = from
        let n = t.u16len
        while i < n {
            if TextPatterns.clauseEndChars.contains(t.u16at(i)) { return i }
            i += 1
        }
        return nil
    }

    // MARK: spacing & punctuation

    public func fixSpacingAndPunctuation(_ text: String) -> String {
        var t = Rx("[ \\t]+").replace(text, " ")
        t = Rx(" +([,.!?;:।])").replace(t, "$1")
        t = Rx(",(?: *,)+").replace(t, ",")
        t = Rx(",+ *([.!?;।])").replace(t, "$1")
        t = Rx("([!?])\\.+").replace(t, "$1")
        t = Rx("(?<!\\.)\\.\\.(?!\\.)").replace(t, ".")
        t = Rx("([,;!?])(?=\\p{L})").replace(t, "$1 ")
        t = Rx("^[ ,;:]+", multiline: true).replace(t, "")
        t = Rx(" *\n *").replace(t, "\n")
        t = Rx("\n{3,}").replace(t, "\n\n")
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    // MARK: capitalisation

    private static let sentenceStart = Rx("(^|[.!?।] +|\n *)(\\p{Ll})")
    private static let abbreviationEnd = Rx("(?i)(?:^|\\s)(?:i\\.e|e\\.g|vs|approx|et al)\\.$")
    private static let loneI = Rx("\(S)i(?!\\.e\\.)\(E)")

    public func capitalize(_ text: String, startsSentence: Bool = true) -> String {
        var t = Self.sentenceStart.replace(text) { g, range in
            let atTextStart = range.location == 0 && g[1].isEmpty
            let afterAbbreviation = Self.abbreviationEnd.containsMatch(text.u16sub(0, range.location + 1))
            if (atTextStart && !startsSentence) || afterAbbreviation { return g[0] }
            return g[1] + g[2].uppercased()
        }
        t = Self.loneI.replace(t, "I")
        return t
    }

    // MARK: final punctuation

    public func addFinalPunctuation(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let units = Array(text.utf16)
        guard TextPatterns.isWordChar(units.last!) else { return text }
        let lastLetter = units.last(where: TextPatterns.isLetter)
        let stop = (lastLetter.map(TextPatterns.isDevanagari) ?? false) ? "।" : "."
        return text + stop
    }
}
