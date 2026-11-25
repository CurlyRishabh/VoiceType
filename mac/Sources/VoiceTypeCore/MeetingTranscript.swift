import Foundation

/// Which side of a call a line came from: this Mac's microphone ("Me") or the sound of other apps,
/// i.e. everyone else on the call ("Others"). Two channels give two speakers without diarization.
public enum MeetingChannel: String, Codable, CaseIterable, Sendable {
    case me, others

    public var label: String { self == .me ? "Me" : "Others" }
    /// The channel's audio file in the meeting folder.
    public var fileName: String { self == .me ? "mic.wav" : "system.wav" }
}

/// Recognised text with times in seconds, relative to the start of the audio it came from.
public struct TimedText: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// One piece of the transcript, timed from the start of the meeting.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var channel: MeetingChannel
    public var text: String
    /// Language Whisper decoded the chunk in ("en", "hi"); "" when the engine doesn't say.
    public var language: String
    /// Which of the other people said it (1, 2…), once they were told apart by voice; nil for Me,
    /// and for Others until (or unless) more than one voice was found.
    public var voice: Int?

    public init(start: Double, end: Double, channel: MeetingChannel, text: String, language: String = "", voice: Int? = nil) {
        self.start = start; self.end = end; self.channel = channel; self.text = text; self.language = language; self.voice = voice
    }

    enum CodingKeys: String, CodingKey { case start, end, channel, speaker, text, language, voice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        channel = try c.decode(MeetingChannel.self, forKey: .channel)
        text = try c.decode(String.self, forKey: .text)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        voice = try c.decodeIfPresent(Int.self, forKey: .voice)
    }

    /// Times rounded to 10 ms, and the speaker label written out for people reading the JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode((start * 100).rounded() / 100, forKey: .start)
        try c.encode((end * 100).rounded() / 100, forKey: .end)
        try c.encode(channel, forKey: .channel)
        try c.encode(voice.map { "Speaker \($0)" } ?? channel.label, forKey: .speaker)
        try c.encode(text, forKey: .text)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(voice, forKey: .voice)
    }
}

/// A transcript line as shown and rendered: consecutive segments of one speaker, merged.
public struct TranscriptLine: Equatable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var channel: MeetingChannel
    public var text: String
    /// A note typed by Me during (or after) the meeting, not speech.
    public var isNote = false
    /// Which of the others (1, 2…), when they were told apart by voice.
    public var voice: Int?
    /// That speaker's name ("Speaker 2" until renamed).
    public var name: String?

    /// "Me", "Others", "Speaker 2" (or the name given to them) or "My note".
    public var label: String { isNote ? "My note" : name ?? channel.label }
}

/// A note typed while the meeting runs (or later), at `at` seconds into the meeting.
public struct MeetingNote: Codable, Equatable, Sendable {
    public var at: Double
    public var text: String
    public init(at: Double, text: String) { self.at = at; self.text = text }
}

public enum MeetingTranscript {
    /// A new line starts after this much silence from the same speaker, or once a line covers this
    /// long, so the timestamps stay useful for citing.
    public static let maxGap = 20.0
    public static let maxLineSeconds = 120.0

    /// Both channels in time order, consecutive same-speaker segments merged into one line.
    /// `names`: what the others told apart by voice are called (voice number → name).
    public static func lines(_ segments: [TranscriptSegment], maxGap: Double = maxGap, maxLineSeconds: Double = maxLineSeconds,
                             names: [Int: String] = [:]) -> [TranscriptLine] {
        let sorted = segments.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
        var out: [TranscriptLine] = []
        for s in sorted {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = out.last, last.channel == s.channel, last.voice == s.voice, s.start - last.end <= maxGap, s.end - last.start <= maxLineSeconds {
                last.text += " " + text
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(TranscriptLine(id: out.count, start: s.start, end: s.end, channel: s.channel, text: text,
                                          voice: s.voice, name: s.voice.map { names[$0] ?? "Speaker \($0)" }))
            }
        }
        return out
    }

    /// Speech lines with the typed notes placed at their times (a note goes after speech that
    /// starts at the same moment). Ids are positions in the result.
    public static func lines(_ segments: [TranscriptSegment], notes: [MeetingNote], names: [Int: String] = [:]) -> [TranscriptLine] {
        let speech = lines(segments, names: names)
        guard !notes.isEmpty else { return speech }
        var out: [TranscriptLine] = []
        var pending = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.at < $1.at }[...]
        func flush(before t: Double?) {
            while let n = pending.first, t.map({ n.at < $0 }) ?? true {
                out.append(TranscriptLine(id: 0, start: n.at, end: n.at, channel: .me,
                                          text: n.text.trimmingCharacters(in: .whitespacesAndNewlines), isNote: true))
                pending.removeFirst()
            }
        }
        for l in speech {
            flush(before: l.start)
            out.append(l)
        }
        flush(before: nil)
        for i in out.indices { out[i].id = i }
        return out
    }

    /// Words with at least one letter or digit ("—" and stray punctuation don't count).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    public static func wordCount(_ segments: [TranscriptSegment]) -> Int { segments.reduce(0) { $0 + wordCount($1.text) } }

    /// "00:12:34".
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// Without headphones the mic also hears the other people, so their words come out twice: once as
/// Others (the clean system audio) and once, fainter, as Me. Drops a Me segment whose words are, for
/// the most part, a contiguous copy of what Others said *during that segment*. Deliberately
/// conservative: people answer with the same common words all the time ("I think we can do that"
/// during a long Others turn), so only runs of 3 words in a row count, only the Others words spoken
/// inside the Me segment's own time span are looked at, and short lines need an exact match. A Me
/// segment that mixes real speech with echo is kept.
public enum EchoFilter {
    /// Seconds around the Me segment in which Others' words count (segment edges from two channels
    /// and the word times estimated inside a segment are both approximate).
    public static let slack = 1.5
    /// Words in a row that must match.
    public static let run = 3
    /// Share of the Me segment's words that must sit inside such runs.
    public static let threshold = 0.8
    /// Shorter lines ("Okay.", "Yes, sure") are dropped only when an Others line that overlaps them
    /// in time (no slack: an echo is simultaneous, a reply such as "Good morning." comes after) says
    /// exactly the same.
    public static let minWords = 4

    public static func apply(_ segments: [TranscriptSegment], slack: Double = slack) -> (segments: [TranscriptSegment], removed: Int) {
        let others = segments.filter { $0.channel == .others }.sorted { $0.start < $1.start }
        guard !others.isEmpty else { return (segments, 0) }
        var removed = 0
        let kept = segments.filter { s in
            guard s.channel == .me else { return true }
            let window = (s.start - slack)...(s.end + slack)
            let overlapping = others.filter { $0.start <= window.upperBound && $0.end >= window.lowerBound }
            guard !overlapping.isEmpty else { return true }
            let heard = overlapping.flatMap { wordsSpoken(in: $0, within: window) }
            let simultaneous = overlapping.filter { $0.start < s.end && $0.end > s.start }
            guard isEcho(words(s.text), heard: heard, lines: simultaneous.map { words($0.text) }) else { return true }
            removed += 1
            return false
        }
        return (kept, removed)
    }

    /// The words of `seg` said within `window`, placing its words evenly over the segment (Whisper
    /// gives times per segment, not per word). Joined in time order with the neighbouring segments,
    /// an echo that crosses a segment boundary still matches.
    static func wordsSpoken(in seg: TranscriptSegment, within window: ClosedRange<Double>) -> [String] {
        let w = words(seg.text)
        let span = max(seg.end - seg.start, 0)
        return w.enumerated().filter { i, _ in window.contains(seg.start + (Double(i) + 0.5) / Double(w.count) * span) }.map(\.element)
    }

    /// `mine`: the Me segment's words. `heard`: what Others said meanwhile. `lines`: the whole Others
    /// lines that overlap the Me segment itself (for the exact match of a short line).
    static func isEcho(_ mine: [String], heard: [String], lines: [[String]]) -> Bool {
        guard !mine.isEmpty else { return false }
        if mine.count < minWords { return lines.contains(mine) }
        guard heard.count >= run else { return false }
        let runs = Set((0...(heard.count - run)).map { heard[$0..<($0 + run)].joined(separator: " ") })
        var covered = [Bool](repeating: false, count: mine.count)
        for i in 0...(mine.count - run) where runs.contains(mine[i..<(i + run)].joined(separator: " ")) {
            for k in i..<(i + run) { covered[k] = true }
        }
        return Double(covered.filter { $0 }.count) / Double(mine.count) >= threshold
    }

    /// Convenience for tests and callers with plain text: `theirs` is taken as said during `mine`.
    public static func isEcho(_ mine: String, of theirs: String) -> Bool {
        isEcho(words(mine), heard: words(theirs), lines: [words(theirs)])
    }

    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return lowered.split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
}

/// Whisper output for one meeting chunk -> what is kept. Dictation's filter judges a whole recording;
/// a meeting needs the same judgement per chunk, or the near-silence phrases never get caught.
public enum MeetingTextFilter {
    /// What the previous chunk of a channel said (after filtering) and when it ended.
    public struct Previous: Equatable, Sendable {
        public var text: String
        public var end: Double
        public init(text: String, end: Double) { self.text = text; self.end = end }
    }

    /// A chunk repeating the one right before it (within this many seconds) is a decoder loop.
    public static let repeatWindow = 15.0
    /// ...when it is at least this long: "Okay." twice is normal conversation.
    public static let repeatMinWords = 3

    /// `speechMillis`: speech the VAD found in the chunk, which spans `start`...`end` seconds of the
    /// meeting. `previous`: the channel's previous chunk. Returns what is kept, and what to pass as
    /// `previous` for the next chunk of this channel.
    public static func clean(_ segments: [TimedText], speechMillis: Int, previous: Previous?, start: Double, end: Double)
        -> (kept: [TimedText], previous: Previous) {
        // The classic near-silence inventions ("Thank you.", "you") on a chunk with little speech.
        let joined = segments.map(\.text).joined(separator: " ")
        guard !HallucinationFilter.clean(joined, speechMillis: speechMillis).isEmpty else { return ([], Previous(text: "", end: end)) }
        var out: [TimedText] = []
        for s in segments {
            let t = HallucinationFilter.clean(s.text, speechMillis: .max) // tags and decoder loops only
            guard t.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if let last = out.last, key(last.text) == key(t) { // the same sentence twice in a row
                out[out.count - 1].end = max(last.end, s.end)
                continue
            }
            out.append(TimedText(text: t, start: s.start, end: s.end))
        }
        let text = out.map(\.text).joined(separator: " ")
        let next = Previous(text: text, end: end)
        // A chunk that only repeats the one just before it is Whisper looping over noise or hold
        // music, not someone saying the same thing again (that would be minutes apart, or short).
        if let previous, !out.isEmpty, start - previous.end <= repeatWindow,
           EchoFilter.words(text).count >= repeatMinWords, key(text) == key(previous.text) {
            return ([], next)
        }
        return (out, next)
    }

    static func key(_ text: String) -> String { EchoFilter.words(text).joined(separator: " ") }
}

/// Clean-up for meeting text. Dictation's rules would change what people said: "comma" or "new
/// line" in conversation, "no wait, six" read as a self-correction, "like" and "you know" removed. So
/// only the safe parts run: Hindi in the chosen script, capitals, and the Dictionary.
public struct MeetingCleanup: Sendable {
    public var script: OutputScript
    public var dictionary: PersonalDictionary

    public init(script: OutputScript = .latin, dictionary: PersonalDictionary = .empty) {
        self.script = script
        self.dictionary = dictionary
    }

    public func options(startsSentence: Bool) -> CleanupOptions {
        var o = CleanupOptions()
        o.applySpokenCommands = false
        o.applySelfCorrections = false
        o.removeFillers = false
        o.addFinalPunctuation = false // Whisper segments can end mid-sentence
        o.autoCapitalize = true
        o.startsSentence = startsSentence
        o.dictionary = dictionary
        return o
    }

    /// `previous`: the text just before this on the same channel (decides the first capital).
    public func clean(_ text: String, previous: String?) -> String {
        let scripted = script == .latin ? Transliterator.toLatin(text) : text
        return RuleCleaner().clean(scripted, options(startsSentence: TextJoin.startsSentence(previous)))
    }
}
