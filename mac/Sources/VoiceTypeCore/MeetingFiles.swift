import Foundation

/// What `meeting.json` holds: everything the Meetings list shows without opening the transcript.
public struct MeetingInfo: Codable, Equatable, Sendable {
    /// `partial`: transcribed, but some chunks failed (their audio is kept).
    public enum Status: String, Codable, Sendable {
        case recording, transcribing, ready, partial, failed

        /// There is a transcript to show and copy.
        public var hasTranscript: Bool { self == .ready || self == .partial }

        /// After transcribing `chunks` parts of which `failed` failed for good.
        public static func after(chunks: Int, failed: Int) -> Status {
            if chunks > 0 && failed >= chunks { return .failed }
            return failed > 0 ? .partial : .ready
        }

        /// Whether the audio stays once the transcript is saved: only a complete one lets it go.
        public func keepsAudio(setting: Bool) -> Bool { setting || self != .ready }
    }
    public enum StopReason: String, Codable, Sendable { case user, maxLength, sleep, lowDisk, writeError, quit, crash, callEnded }
    /// What the system-audio channel delivered. `silent` = only digital silence (permission denied,
    /// or nothing played at all); `unavailable` = the tap could not be created.
    public enum SystemAudio: String, Codable, Sendable { case unknown, ok, silent, unavailable }

    public var version = 1
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: Status
    public var stopReason: StopReason?
    /// Meeting length (the longer channel), seconds.
    public var durationSeconds: Double = 0
    /// Time spent decoding, all chunks of both channels.
    public var decodeSeconds: Double = 0
    /// decodeSeconds / durationSeconds.
    public var rtf: Double?
    /// Stop → transcript ready.
    public var tailSeconds: Double?
    public var model = ""
    /// The language setting at the start: "en", "hi" or "auto".
    public var languageSetting = "en"
    /// Languages the chunks were decoded in.
    public var languages: [String] = []
    public var wordCount = 0
    public var systemAudio: SystemAudio = .unknown
    public var echoLinesRemoved = 0
    /// Chunks that could not be transcribed, and how much audio they held (seconds).
    public var failedChunks = 0
    public var missingSeconds: Double = 0
    public var audioKept = false
    public var error: String?
    /// How many different voices were found among the others (0 = not checked, or no Others speech).
    public var speakers = 0
    /// Names given to them in the Meetings tab: "2" → "Priya".
    public var speakerNames: [String: String] = [:]
    /// Telling the others apart is still to do (it needs the audio, so retention waits for it).
    public var speakersPending = false

    /// speakerNames keyed by voice number.
    public var names: [Int: String] {
        Dictionary(speakerNames.compactMap { k, v in Int(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a }) // "1" and "01"
    }

    public init(title: String, startedAt: Date, status: Status = .recording) {
        self.title = title
        self.startedAt = startedAt
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case version, title, startedAt, endedAt, status, stopReason, durationSeconds, decodeSeconds, rtf, tailSeconds
        case model, languageSetting, languages, wordCount, systemAudio, echoLinesRemoved, failedChunks, missingSeconds, audioKept, error
        case speakers, speakerNames, speakersPending
    }

    /// Lenient: a field added in a later version, or a hand-edited file, doesn't hide the meeting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .failed
        stopReason = try? c.decodeIfPresent(StopReason.self, forKey: .stopReason)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        decodeSeconds = try c.decodeIfPresent(Double.self, forKey: .decodeSeconds) ?? 0
        rtf = try c.decodeIfPresent(Double.self, forKey: .rtf)
        tailSeconds = try c.decodeIfPresent(Double.self, forKey: .tailSeconds)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        languageSetting = try c.decodeIfPresent(String.self, forKey: .languageSetting) ?? "en"
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        systemAudio = (try? c.decodeIfPresent(SystemAudio.self, forKey: .systemAudio)) ?? .unknown
        echoLinesRemoved = try c.decodeIfPresent(Int.self, forKey: .echoLinesRemoved) ?? 0
        failedChunks = try c.decodeIfPresent(Int.self, forKey: .failedChunks) ?? 0
        missingSeconds = try c.decodeIfPresent(Double.self, forKey: .missingSeconds) ?? 0
        audioKept = try c.decodeIfPresent(Bool.self, forKey: .audioKept) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        speakers = try c.decodeIfPresent(Int.self, forKey: .speakers) ?? 0
        speakerNames = (try? c.decodeIfPresent([String: String].self, forKey: .speakerNames)) ?? [:]
        speakersPending = try c.decodeIfPresent(Bool.self, forKey: .speakersPending) ?? false
    }
}

/// transcript.md and the "Copy" texts.
public enum MeetingRender {
    /// For pasting into Claude or Codex together with the transcript. No summary happens on the Mac.
    public static let aiInstructions = """
    This is an automatic transcript of a meeting. "Me" is the person who recorded it; "Others" is everyone else on the call. \
    Please summarise it in a few sentences, then list the decisions made, the action items (with owner and due date when \
    they were said) and the open questions. Cite the timestamp, like [00:12:34], for each point. "Speaker 1", "Speaker 2"… are the \
    other people told apart by voice (this can occasionally merge or split people). Lines marked "My note" were \
    typed by Me during the meeting: treat them as what Me found important. Speech recognition can mishear names and \
    numbers: flag anything that looks wrong instead of guessing.
    """

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    /// Title, date, time span, speakers, model and languages.
    public static func header(_ info: MeetingInfo, timeZone: TimeZone = .current) -> String {
        let day = formatter("EEEE, d MMMM yyyy", timeZone).string(from: info.startedAt)
        let clock = formatter("h:mm a", timeZone)
        let end = info.endedAt ?? info.startedAt.addingTimeInterval(info.durationSeconds)
        var lines = [
            "# \(info.title)",
            "",
            "- **When:** \(day), \(clock.string(from: info.startedAt)) – \(clock.string(from: end)) (\(MeetingDates.duration(info.durationSeconds)))",
            info.speakers > 1
                ? "- **Speakers:** Me (this Mac's microphone); the others on the call, told apart by voice: "
                    + (1...info.speakers).map { n in info.names[n].map { "\($0) (Speaker \(n))" } ?? "Speaker \(n)" }.joined(separator: ", ")
                : "- **Speakers:** Me (this Mac's microphone), Others (sound from other apps: everyone else on the call)",
        ]
        var engine: [String] = []
        if !info.model.isEmpty { engine.append(info.model) }
        let langs = (info.languages.isEmpty ? LanguageSelection.languages(for: info.languageSetting).sorted() : info.languages).map(languageName)
        engine.append(langs.joined(separator: " + "))
        engine.append("\(info.wordCount.formatted(.number.locale(Locale(identifier: "en_US")))) words")
        lines.append("- **Transcribed on this Mac:** " + engine.joined(separator: " · "))
        if info.systemAudio == .silent || info.systemAudio == .unavailable {
            lines.append("- **Note:** no sound from other apps was captured, so only Me was transcribed.")
        }
        if info.status == .partial {
            lines.append("- **Note:** about \(MeetingDates.duration(info.missingSeconds)) of speech could not be transcribed; the audio is kept in this folder.")
        }
        return lines.joined(separator: "\n")
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "hi": return "Hindi"
        default: return code
        }
    }

    /// "[00:12:34] **Me:** text", one paragraph per line.
    public static func body(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return "_No speech was transcribed._" }
        return lines.map { "[\(MeetingTranscript.timestamp($0.start))] \($0.isNote ? "📝 " : "")**\($0.label):** \($0.text)" }.joined(separator: "\n\n")
    }

    /// The whole transcript.md: header, the instruction block for Claude/Codex, then the transcript.
    public static func markdown(_ info: MeetingInfo, lines: [TranscriptLine], timeZone: TimeZone = .current) -> String {
        """
        \(header(info, timeZone: timeZone))

        > **For Claude or Codex:** \(aiInstructions)

        ## Transcript

        \(body(lines))

        """
    }

    /// "Copy transcript": header and transcript, without the instructions.
    public static func plain(_ info: MeetingInfo, lines: [TranscriptLine], timeZone: TimeZone = .current) -> String {
        "\(header(info, timeZone: timeZone))\n\n## Transcript\n\n\(body(lines))\n"
    }

    /// "Copy for AI": instructions first, then the transcript.
    public static func forAI(_ info: MeetingInfo, lines: [TranscriptLine], timeZone: TimeZone = .current) -> String {
        "\(aiInstructions)\n\n---\n\n\(plain(info, lines: lines, timeZone: timeZone))"
    }
}

/// Short date and length texts for the Meetings list.
public enum MeetingDates {
    /// "45 min", "1 h 05 min", "40 s".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        return m < 60 ? "\(m) min" : String(format: "%d h %02d min", m / 60, m % 60)
    }

    /// "Today at 3:10 PM", "Yesterday at 9:05 AM", "Mon 17 Nov at 4:00 PM".
    public static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = MeetingRender.formatter("h:mm a", calendar.timeZone).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday at \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = MeetingRender.formatter(sameYear ? "EEE d MMM" : "d MMM yyyy", calendar.timeZone).string(from: date)
        return "\(day) at \(time)"
    }
}

/// The per-meeting folder: `Meetings/<YYYY-MM-DD HHmm> <title>/` with meeting.json, transcript.md,
/// transcript.json and, while recording (or when kept), mic.wav and system.wav.
public enum MeetingFiles {
    public static let infoFile = "meeting.json"
    public static let transcriptJSON = "transcript.json"
    public static let transcriptMarkdown = "transcript.md"
    public static let notesFile = "notes.json"

    /// "2026-11-25 1402 Weekly sync". Characters Finder or the shell trip over are replaced.
    public static func folderName(start: Date, title: String, timeZone: TimeZone = .current) -> String {
        "\(MeetingRender.formatter("yyyy-MM-dd HHmm", timeZone).string(from: start)) \(safeTitle(title))"
    }

    public static func safeTitle(_ title: String) -> String {
        let cleaned = title.unicodeScalars.map { s -> Character in
            CharacterSet.controlCharacters.contains(s) || "/:\\".unicodeScalars.contains(s) ? " " : Character(s)
        }
        var t = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while t.hasPrefix(".") { t.removeFirst() } // no hidden folders
        t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Meeting" : t
    }

    /// `root/name`, or `root/name 2`, `name 3`… if taken.
    public static func uniqueFolder(in root: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = root.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func writeInfo(_ info: MeetingInfo, to folder: URL) throws {
        try encoder.encode(info).write(to: folder.appendingPathComponent(infoFile), options: .atomic)
    }

    public static func readInfo(_ folder: URL) -> MeetingInfo? {
        (try? Data(contentsOf: folder.appendingPathComponent(infoFile))).flatMap { try? decoder.decode(MeetingInfo.self, from: $0) }
    }

    /// transcript.json. `status` says whether every part was transcribed (ready) or not (partial,
    /// failed), so a meeting recovered from this file alone knows whether its audio may go.
    public struct TranscriptFile: Codable, Equatable, Sendable {
        public var version = 1
        public var status: MeetingInfo.Status?
        public var segments: [TranscriptSegment]

        public init(status: MeetingInfo.Status?, segments: [TranscriptSegment]) {
            self.status = status
            self.segments = segments
        }
    }

    /// transcript.json (the segments and the status) and transcript.md (rendered from them).
    public static func writeTranscript(_ segments: [TranscriptSegment], info: MeetingInfo, to folder: URL, timeZone: TimeZone = .current) throws {
        let file = TranscriptFile(status: info.status, segments: segments)
        try encoder.encode(file).write(to: folder.appendingPathComponent(transcriptJSON), options: .atomic)
        try writeMarkdown(segments, info: info, to: folder, timeZone: timeZone)
    }

    public static func writeMarkdown(_ segments: [TranscriptSegment], info: MeetingInfo, to folder: URL, timeZone: TimeZone = .current) throws {
        let md = MeetingRender.markdown(info, lines: MeetingTranscript.lines(segments, notes: readNotes(folder), names: info.names), timeZone: timeZone)
        try Data(md.utf8).write(to: folder.appendingPathComponent(transcriptMarkdown), options: .atomic)
    }

    public static func readSegments(_ folder: URL) -> [TranscriptSegment] { readTranscript(folder) ?? [] }

    /// nil when transcript.json is missing or unreadable (it is written in one go, so a readable one is complete).
    public static func readTranscript(_ folder: URL) -> [TranscriptSegment]? { readTranscriptFile(folder)?.segments }

    public static func readTranscriptFile(_ folder: URL) -> TranscriptFile? {
        (try? Data(contentsOf: folder.appendingPathComponent(transcriptJSON))).flatMap { try? decoder.decode(TranscriptFile.self, from: $0) }
    }

    /// A meeting cut off after transcript.json was saved (but before meeting.json said so): its info
    /// from that file. Ready only when the file says every part was transcribed; anything else, or a
    /// file without a status, keeps the audio. nil when there is no readable transcript.
    public static func recoveredInfo(_ base: MeetingInfo, folder: URL, keepAudio: Bool) -> (info: MeetingInfo, segments: [TranscriptSegment])? {
        guard let file = readTranscriptFile(folder) else { return nil }
        var info = base
        info.status = file.status.flatMap { $0.hasTranscript || $0 == .failed ? $0 : nil } ?? .partial
        if info.status == .partial && info.error == nil { info.error = "The app stopped while saving this transcript; some parts may be missing." }
        info.wordCount = MeetingTranscript.wordCount(file.segments)
        info.audioKept = info.status.keepsAudio(setting: keepAudio)
        return (info, file.segments)
    }

    /// notes.json: what Me typed during or after the meeting. Empty when there is none.
    public static func readNotes(_ folder: URL) -> [MeetingNote] {
        (try? Data(contentsOf: folder.appendingPathComponent(notesFile))).flatMap { try? decoder.decode([MeetingNote].self, from: $0) } ?? []
    }

    public static func writeNotes(_ notes: [MeetingNote], to folder: URL) throws {
        try encoder.encode(notes).write(to: folder.appendingPathComponent(notesFile), options: .atomic)
    }

    public static func audioFiles(_ folder: URL) -> [URL] {
        MeetingChannel.allCases.map { folder.appendingPathComponent($0.fileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func deleteAudio(_ folder: URL) {
        audioFiles(folder).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

/// How long meeting audio stays after the transcript is saved (Settings › Meetings).
public enum AudioRetention {
    /// Days; 0 = delete as soon as the transcript is saved, -1 = keep until the meeting is deleted.
    public static let choices = [0, 1, 7, 30, -1]
    public static let defaultDays = 7

    public static func title(_ days: Int) -> String {
        switch days {
        case 0: return "Delete right away"
        case -1: return "Keep until I delete the meeting"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// Kept at all after transcription.
    public static func keeps(_ days: Int) -> Bool { days != 0 }

    /// The audio of a finished meeting whose time is up. Meetings being recorded or transcribed,
    /// and ones without audio, never qualify; partial/failed ones keep theirs for the same period.
    public static func expired(_ info: MeetingInfo, days: Int, now: Date = Date()) -> Bool {
        guard days >= 0, info.audioKept, !info.speakersPending, info.status != .recording, info.status != .transcribing else { return false }
        // A partial or failed transcript's audio is what can fix it: never less than the default.
        let days = info.status == .ready ? days : max(days, defaultDays)
        let end = info.endedAt ?? info.startedAt.addingTimeInterval(info.durationSeconds)
        return now.timeIntervalSince(end) >= Double(days) * 86_400
    }
}
