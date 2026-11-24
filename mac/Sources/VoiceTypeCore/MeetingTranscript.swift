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

    public init(start: Double, end: Double, channel: MeetingChannel, text: String, language: String = "") {
        self.start = start; self.end = end; self.channel = channel; self.text = text; self.language = language
    }

    enum CodingKeys: String, CodingKey { case start, end, channel, speaker, text, language }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        channel = try c.decode(MeetingChannel.self, forKey: .channel)
        text = try c.decode(String.self, forKey: .text)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
    }

    /// Times rounded to 10 ms, and the speaker label written out for people reading the JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode((start * 100).rounded() / 100, forKey: .start)
        try c.encode((end * 100).rounded() / 100, forKey: .end)
        try c.encode(channel, forKey: .channel)
        try c.encode(channel.label, forKey: .speaker)
        try c.encode(text, forKey: .text)
        try c.encode(language, forKey: .language)
    }
}

/// A transcript line as shown and rendered: consecutive segments of one speaker, merged.
public struct TranscriptLine: Equatable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var channel: MeetingChannel
    public var text: String
}

public enum MeetingTranscript {
    /// A new line starts after this much silence from the same speaker, or once a line covers this
    /// long, so the timestamps stay useful for citing.
    public static let maxGap = 20.0
    public static let maxLineSeconds = 120.0

    /// Both channels in time order, consecutive same-speaker segments merged into one line.
    public static func lines(_ segments: [TranscriptSegment], maxGap: Double = maxGap, maxLineSeconds: Double = maxLineSeconds) -> [TranscriptLine] {
        let sorted = segments.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
        var out: [TranscriptLine] = []
        for s in sorted {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = out.last, last.channel == s.channel, s.start - last.end <= maxGap, s.end - last.start <= maxLineSeconds {
                last.text += " " + text
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(TranscriptLine(id: out.count, start: s.start, end: s.end, channel: s.channel, text: text))
            }
        }
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
/// Others (the clean system audio) and once, fainter, as Me. Drops a Me segment whose words closely
/// match what Others said at the same time. Deliberately conservative: a Me segment that mixes real
/// speech with echo is kept.
public enum EchoFilter {
    /// How far apart in time the two may be (seconds): segment edges from two channels never line up exactly.
    public static let slack = 1.5
    /// Share of the Me segment's words that must appear, in order, in the overlapping Others text.
    public static let threshold = 0.7

    public static func apply(_ segments: [TranscriptSegment], slack: Double = slack, threshold: Double = threshold) -> (segments: [TranscriptSegment], removed: Int) {
        let others = segments.filter { $0.channel == .others }
        guard !others.isEmpty else { return (segments, 0) }
        var removed = 0
        let kept = segments.filter { s in
            guard s.channel == .me else { return true }
            let overlapping = others.filter { $0.start < s.end + slack && $0.end > s.start - slack }
            guard !overlapping.isEmpty,
                  isEcho(s.text, of: overlapping.map(\.text).joined(separator: " "), threshold: threshold) else { return true }
            removed += 1
            return false
        }
        return (kept, removed)
    }

    /// True when `mine` reads as an echo of `theirs`. One or two words ("Okay.", "Yes, sure") only on
    /// an exact match: people really do say those while the others talk.
    public static func isEcho(_ mine: String, of theirs: String, threshold: Double = threshold) -> Bool {
        let a = words(mine), b = words(theirs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.count < 3 { return a == b }
        return Double(commonSubsequence(a, b)) / Double(a.count) >= threshold
    }

    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return lowered.split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    /// Length of the longest common subsequence of two word lists.
    static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1), cur = prev
        for x in a {
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Whisper output for one meeting chunk -> what is kept. Dictation's filter judges a whole recording;
/// a meeting needs the same judgement per chunk, or the near-silence phrases never get caught.
public enum MeetingTextFilter {
    /// `speechMillis`: speech the VAD found in the chunk. `previous`: the text kept from the previous
    /// chunk of the same channel.
    public static func clean(_ segments: [TimedText], speechMillis: Int, previous: String?) -> [TimedText] {
        // The classic near-silence inventions ("Thank you.", "you") on a chunk with little speech.
        let joined = segments.map(\.text).joined(separator: " ")
        guard !HallucinationFilter.clean(joined, speechMillis: speechMillis).isEmpty else { return [] }
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
        // A chunk that only repeats the previous one word for word is Whisper looping over noise or
        // hold music, not someone saying the same thing again a few seconds later.
        if let previous, !out.isEmpty, key(out.map(\.text).joined(separator: " ")) == key(previous) { return [] }
        return out
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
