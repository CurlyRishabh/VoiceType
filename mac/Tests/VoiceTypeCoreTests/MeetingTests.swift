import Foundation
import Testing
@testable import VoiceTypeCore

private func seg(_ start: Double, _ end: Double, _ ch: MeetingChannel, _ text: String) -> TranscriptSegment {
    TranscriptSegment(start: start, end: end, channel: ch, text: text, language: "en")
}

@Suite struct MeetingTranscriptTests {
    @Test func mergesConsecutiveSameSpeakerInTimeOrder() {
        let lines = MeetingTranscript.lines([
            seg(10, 12, .others, "Hi, can you hear me?"),
            seg(0, 3, .me, "Okay, let's start."),
            seg(3.5, 6, .me, "First item is the launch."),
            seg(12.5, 14, .others, "Great."),
        ])
        #expect(lines.map(\.channel) == [.me, .others])
        #expect(lines[0].text == "Okay, let's start. First item is the launch.")
        #expect(lines[0].start == 0 && lines[0].end == 6)
        #expect(lines[1].text == "Hi, can you hear me? Great.")
        #expect(lines.map(\.id) == [0, 1])
    }

    @Test func longPauseOrLongTurnStartsANewLine() {
        let gap = MeetingTranscript.lines([seg(0, 2, .me, "One."), seg(30, 32, .me, "Two.")])
        #expect(gap.count == 2)
        let long = MeetingTranscript.lines((0..<15).map { seg(Double($0) * 10, Double($0) * 10 + 9, .me, "Part \($0).") })
        #expect(long.count == 2) // 0–119 s, then the rest
        #expect(long[1].start == 120)
    }

    @Test func interleavedSpeakersStayApart() {
        let lines = MeetingTranscript.lines([seg(0, 4, .me, "A"), seg(2, 5, .others, "B"), seg(6, 7, .me, "C")])
        #expect(lines.map(\.text) == ["A", "B", "C"])
    }

    @Test func dropsEmptySegments() {
        #expect(MeetingTranscript.lines([seg(0, 1, .me, "  "), seg(1, 2, .me, "Hi")]).map(\.text) == ["Hi"])
    }

    @Test func timestampsAndWordCounts() {
        #expect(MeetingTranscript.timestamp(0) == "00:00:00")
        #expect(MeetingTranscript.timestamp(754.9) == "00:12:34")
        #expect(MeetingTranscript.timestamp(3 * 3600 + 5) == "03:00:05")
        #expect(MeetingTranscript.timestamp(-3) == "00:00:00")
        #expect(MeetingTranscript.wordCount("Hello there — it's 5 o'clock.") == 5)
        #expect(MeetingTranscript.wordCount([seg(0, 1, .me, "a b"), seg(1, 2, .others, "c")]) == 3)
    }
}

@Suite struct EchoFilterTests {
    @Test func dropsMyEchoOfOthers() {
        let input = [
            seg(10, 14, .others, "We should ship the beta on Friday after the review."),
            seg(10.2, 14.1, .me, "we should ship the beta on friday after review"),
        ]
        let (kept, removed) = EchoFilter.apply(input)
        #expect(removed == 1)
        #expect(kept.map(\.channel) == [.others])
    }

    @Test func keepsMyOwnWords() {
        let input = [
            seg(10, 14, .others, "We should ship the beta on Friday."),
            seg(11, 15, .me, "I think Monday is safer because QA is out."),
        ]
        #expect(EchoFilter.apply(input).removed == 0)
    }

    @Test func needsOverlapInTime() {
        let input = [seg(10, 14, .others, "We should ship the beta on Friday."), seg(40, 44, .me, "We should ship the beta on Friday.")]
        #expect(EchoFilter.apply(input).removed == 0) // I repeated it later: that's me talking
    }

    @Test func toleratesEdgesAndSplitSegments() {
        let input = [
            seg(10, 12, .others, "Can everyone see"),
            seg(12, 15, .others, "my screen right now?"),
            seg(9.0, 15.8, .me, "Can everyone see my screen right now"),
        ]
        #expect(EchoFilter.apply(input).removed == 1)
    }

    @Test func mixedSpeechIsKept() {
        // Talking over the others: half of it is mine, so the line stays.
        #expect(!EchoFilter.isEcho("sorry go ahead we should ship the beta", of: "we should ship the beta on friday"))
    }

    @Test func shortLinesOnlyOnExactMatch() {
        #expect(EchoFilter.isEcho("Okay.", of: "okay"))
        #expect(!EchoFilter.isEcho("Okay.", of: "Okay, let's move on to the next item."))
        #expect(!EchoFilter.isEcho("Yes", of: "No"))
        #expect(!EchoFilter.isEcho("I think so.", of: "So I think the main thing is that we need to get the export out"))
    }

    @Test func toleratesAMisheardWord() {
        // Whisper on the faint echo gets a word wrong: only the words around it stop matching.
        #expect(EchoFilter.isEcho("we should ship the beta on friday after the security review is done",
                                  of: "We should ship the beta on Friday after the safety review is done."))
    }

    @Test func commonWordsInADifferentOrderAreNotAnEcho() {
        #expect(!EchoFilter.isEcho("That should be fine.", of: "the rest of it should be fine what I want"))
        #expect(!EchoFilter.isEcho("Yes, we can do that.", of: "if we can do the migration first then the"))
    }

    /// A long Others turn (~70 words over ~27 s, in three Whisper segments) and short Me replies
    /// placed at every point of it: none of the replies may go, however many common words they share
    /// with the turn. (The round-1 filter dropped 11 of these 13.)
    static let monologue = """
    So I think the main thing is that we need to get the export out before the review, and I know that it is not \
    going to be easy, but if we can do the migration first then the rest of it should be fine. What I want to do is \
    make sure that you and I are on the same page about that, so that we do not have to go back and change it again.
    """

    static func monologueSegments() -> [TranscriptSegment] {
        let w = monologue.split(separator: " ").map(String.init)
        let per = w.count / 3, rate = 2.6
        var t = 0.0
        return (0..<3).map { k in
            let part = k < 2 ? Array(w[(k * per)..<((k + 1) * per)]) : Array(w[(2 * per)...])
            let d = Double(part.count) / rate
            defer { t += d }
            return seg(t, t + d, .others, part.joined(separator: " "))
        }
    }

    @Test func longUnrelatedOthersTurnKeepsMyReplies() {
        let others = Self.monologueSegments()
        let replies = ["I think so.", "Yeah, that is fine.", "I know that.", "That should be fine.", "Yes, we can do that.",
                       "I think we can do that.", "Okay, so we do it first.", "I do not want to change it again.",
                       "No, I think that is not going to be easy.", "Right, I am on the same page.", "We need to do the migration first.",
                       "I think it is going to be fine if we do that.", "Can you send me the invoice numbers by Friday?"]
        for reply in replies {
            let length = Double(reply.split(separator: " ").count) / 2.6
            for step in 0..<60 {
                let at = Double(step) * 0.5 - 1
                let (_, removed) = EchoFilter.apply(others + [seg(at, at + length, .me, reply)])
                #expect(removed == 0, "dropped “\(reply)” at \(at) s")
            }
        }
    }

    @Test func echoInsideALongOthersTurnIsDropped() {
        let others = Self.monologueSegments()
        // Others' segment 2 starts "...going to be easy, but if we can do the migration first..."; the mic
        // picks up a stretch of it at the same moment.
        let s = others[1]
        let echo = seg(s.start + 1, s.start + 5, .me, "but if we can do the migration first then the rest")
        let (kept, removed) = EchoFilter.apply(others + [echo])
        #expect(removed == 1 && kept.count == 3)
    }

    /// With headphones (no echo at all), people mirror short lines: "Good morning." – "Good morning."
    /// A reply comes after the other line, an echo with it: only the echo goes.
    @Test(arguments: ["Hello?", "Good morning.", "Thank you.", "Bye.", "Okay.", "Thanks, bye.", "Yes.", "Happy new year!"])
    func mirroredShortRepliesStay(_ line: String) {
        let d = Double(line.split(separator: " ").count) / 2.6
        for gap in [0.0, 0.3, 0.6, 1.0, 1.4] {
            let others = seg(10, 10 + d, .others, line)
            let reply = seg(10 + d + gap, 10 + 2 * d + gap, .me, line)
            #expect(EchoFilter.apply([others, reply]).removed == 0, "dropped “\(line)” \(gap) s after")
        }
        // The same words at the same moment in the mic are the echo.
        let echo = seg(10.05, 10 + d + 0.05, .me, line)
        #expect(EchoFilter.apply([seg(10, 10 + d, .others, line), echo]).removed == 1)
    }

    @Test func wordTimesInsideASegment() {
        let s = seg(0, 10, .others, "one two three four five six seven eight nine ten")
        #expect(EchoFilter.wordsSpoken(in: s, within: 2...4.9) == ["three", "four", "five"])
    }
}

@Suite struct MeetingTextFilterTests {
    func t(_ text: String, _ s: Double = 0, _ e: Double = 2) -> TimedText { TimedText(text: text, start: s, end: e) }
    func clean(_ segs: [TimedText], _ speech: Int, _ prev: MeetingTextFilter.Previous? = nil, start: Double = 20, end: Double = 25) -> [TimedText] {
        MeetingTextFilter.clean(segs, speechMillis: speech, previous: prev, start: start, end: end).kept
    }

    @Test func dropsNearSilencePhrasesPerChunk() {
        #expect(clean([t("Thank you for watching!")], 600).isEmpty)
        #expect(clean([t("You")], 400).isEmpty)
        // Real speech with the same words is kept.
        #expect(clean([t("Thank you.")], 900).map(\.text) == ["Thank you."])
    }

    @Test func stripsTagsAndLoops() {
        #expect(clean([t("[Music]"), t("go go go go go now", 2, 4)], 4000) == [t("go now", 2, 4)])
    }

    @Test func collapsesRepeatedSegmentsInAChunk() {
        let out = clean([t("Let's start.", 0, 2), t("let's start", 2, 4), t("Agenda first.", 4, 6)], 6000)
        #expect(out.map(\.text) == ["Let's start.", "Agenda first."])
        #expect(out[0].end == 4)
    }

    @Test func dropsAChunkThatRepeatsTheOneJustBefore() {
        let hold = MeetingTextFilter.Previous(text: "please hold your call is important to us", end: 18)
        #expect(clean([t("Please hold, your call is important to us.")], 5000, hold).isEmpty)
        #expect(clean([t("New words here.")], 5000, hold).count == 1)
    }

    @Test func repeatsFarApartOrShortAreKept() {
        // The same sentence a minute later is someone saying it again.
        let long = MeetingTextFilter.Previous(text: "can everyone see my screen", end: 5)
        #expect(clean([t("Can everyone see my screen?")], 3000, long, start: 60, end: 63).count == 1)
        // "Okay." twice in a row is conversation.
        let okay = MeetingTextFilter.Previous(text: "Okay.", end: 18)
        #expect(clean([t("Okay.")], 600, okay).count == 1)
    }

    @Test func reportsWhatTheNextChunkComparesWith() {
        let r = MeetingTextFilter.clean([t("Hello there everyone.")], speechMillis: 2000, previous: nil, start: 3, end: 7)
        #expect(r.previous == .init(text: "Hello there everyone.", end: 7))
        // Dropped as a repeat: still the reference for a third copy.
        let again = MeetingTextFilter.clean([t("hello there everyone")], speechMillis: 2000, previous: r.previous, start: 9, end: 12)
        #expect(again.kept.isEmpty && again.previous.end == 12)
        // Nothing kept (near-silence phrase): the next chunk has nothing to repeat.
        #expect(MeetingTextFilter.clean([t("you")], speechMillis: 300, previous: r.previous, start: 9, end: 12).previous.text == "")
    }
}

@Suite struct MeetingCleanupTests {
    @Test func keepsWhatPeopleSaid() {
        let c = MeetingCleanup()
        // Dictation would turn these into punctuation, a correction, and drop "like".
        let said = "I'd put a comma there, no wait, a period. It's like five new line items"
        #expect(c.clean(said, previous: nil) == said)
    }

    @Test func capitalsDictionaryAndScript() {
        let c = MeetingCleanup(script: .latin, dictionary: PersonalDictionary([.init("chargebee", "ChargeBee")]))
        #expect(c.clean("the chargebee invoice. i sent it", previous: nil) == "The ChargeBee invoice. I sent it")
        #expect(c.clean("and then we left", previous: "We waited") == "and then we left") // mid-sentence
        #expect(c.clean("कल मीटिंग है", previous: nil) == "Kal meeting hai")
        #expect(MeetingCleanup(script: .devanagari).clean("कल मीटिंग है", previous: nil) == "कल मीटिंग है")
    }
}

@Suite struct MeetingRenderTests {
    var info: MeetingInfo {
        var i = MeetingInfo(title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_764_079_320), status: .ready) // 2025-11-25 14:02 UTC
        i.endedAt = i.startedAt.addingTimeInterval(45 * 60 + 10)
        i.durationSeconds = 45 * 60 + 10
        i.model = "whisper.cpp large-v3-turbo-q5_0"
        i.languages = ["en", "hi"]
        i.wordCount = 1234
        return i
    }

    @Test func markdownLayout() {
        let lines = MeetingTranscript.lines([seg(3, 5, .me, "Hi all."), seg(5.5, 9, .others, "Hello!"), seg(3700, 3702, .me, "Bye.")])
        let md = MeetingRender.markdown(info, lines: lines, timeZone: TimeZone(identifier: "UTC")!)
        #expect(md.hasPrefix("# Weekly sync\n\n- **When:** Tuesday, 25 November 2025, 2:02 PM – 2:47 PM (45 min)\n"))
        #expect(md.contains("- **Transcribed on this Mac:** whisper.cpp large-v3-turbo-q5_0 · English + Hindi · 1,234 words"))
        #expect(md.contains("> **For Claude or Codex:** This is an automatic transcript"))
        #expect(md.contains("cite the timestamp".capitalized) || md.contains("Cite the timestamp"))
        #expect(md.contains("## Transcript\n\n[00:00:03] **Me:** Hi all.\n\n[00:00:05] **Others:** Hello!\n\n[01:01:40] **Me:** Bye.\n"))
    }

    @Test func copyTexts() {
        let lines = MeetingTranscript.lines([seg(0, 1, .others, "Hello")])
        let tz = TimeZone(identifier: "UTC")!
        let plain = MeetingRender.plain(info, lines: lines, timeZone: tz)
        #expect(!plain.contains("For Claude"))
        #expect(plain.contains("[00:00:00] **Others:** Hello"))
        let ai = MeetingRender.forAI(info, lines: lines, timeZone: tz)
        #expect(ai.hasPrefix(MeetingRender.aiInstructions))
        #expect(ai.hasSuffix(plain))
    }

    @Test func partialNote() {
        var i = info
        i.status = .partial
        i.missingSeconds = 75
        #expect(MeetingRender.header(i, timeZone: TimeZone(identifier: "UTC")!).contains("about 1 min of speech could not be transcribed"))
        #expect(MeetingInfo.Status.partial.hasTranscript && MeetingInfo.Status.ready.hasTranscript)
        #expect(!MeetingInfo.Status.transcribing.hasTranscript && !MeetingInfo.Status.failed.hasTranscript)
    }

    @Test func statusAfterTranscribing() {
        #expect(MeetingInfo.Status.after(chunks: 10, failed: 0) == .ready)
        #expect(MeetingInfo.Status.after(chunks: 0, failed: 0) == .ready) // nobody spoke
        #expect(MeetingInfo.Status.after(chunks: 10, failed: 1) == .partial)
        #expect(MeetingInfo.Status.after(chunks: 10, failed: 10) == .failed)
        // Only a complete transcript lets the audio go.
        #expect(!MeetingInfo.Status.ready.keepsAudio(setting: false))
        #expect(MeetingInfo.Status.ready.keepsAudio(setting: true))
        #expect(MeetingInfo.Status.partial.keepsAudio(setting: false))
        #expect(MeetingInfo.Status.failed.keepsAudio(setting: false))
    }

    @Test func emptyAndMicOnly() {
        var i = info
        i.systemAudio = .silent
        let md = MeetingRender.markdown(i, lines: [], timeZone: TimeZone(identifier: "UTC")!)
        #expect(md.contains("_No speech was transcribed._"))
        #expect(md.contains("only Me was transcribed"))
    }

    @Test func dates() {
        #expect(MeetingDates.duration(40) == "40 s")
        #expect(MeetingDates.duration(45 * 60 + 10) == "45 min")
        #expect(MeetingDates.duration(3900) == "1 h 05 min")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_764_079_320) // Tue 25 Nov 2025 14:02
        #expect(MeetingDates.relative(now.addingTimeInterval(-3600), now: now, calendar: cal) == "Today at 1:02 PM")
        #expect(MeetingDates.relative(now.addingTimeInterval(-86_400), now: now, calendar: cal) == "Yesterday at 2:02 PM")
        #expect(MeetingDates.relative(now.addingTimeInterval(-8 * 86_400), now: now, calendar: cal) == "Mon 17 Nov at 2:02 PM")
        #expect(MeetingDates.relative(now.addingTimeInterval(-400 * 86_400), now: now, calendar: cal) == "21 Oct 2024 at 2:02 PM")
    }
}

@Suite struct MeetingFilesTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vt-meeting-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func folderNames() {
        let start = Date(timeIntervalSince1970: 1_764_079_320)
        let utc = TimeZone(identifier: "UTC")!
        #expect(MeetingFiles.folderName(start: start, title: "Weekly sync", timeZone: utc) == "2025-11-25 1402 Weekly sync")
        #expect(MeetingFiles.folderName(start: start, title: " a/b: c\n ", timeZone: utc) == "2025-11-25 1402 a b c")
        #expect(MeetingFiles.safeTitle("..hidden") == "hidden")
        #expect(MeetingFiles.safeTitle("   ") == "Meeting")
        #expect(MeetingFiles.safeTitle(String(repeating: "x", count: 100)).count == 60)
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = MeetingFiles.uniqueFolder(in: root, name: "X")
        try! FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        #expect(MeetingFiles.uniqueFolder(in: root, name: "X").lastPathComponent == "X 2")
    }

    @Test func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var info = MeetingInfo(title: "Sync", startedAt: Date(timeIntervalSince1970: 1_764_079_320))
        info.rtf = 0.031
        info.systemAudio = .ok
        try MeetingFiles.writeInfo(info, to: dir)
        #expect(MeetingFiles.readInfo(dir) == info)
        let segs = [seg(1.234, 2.5, .me, "Hello"), seg(2, 3, .others, "Hi")]
        try MeetingFiles.writeTranscript(segs, info: info, to: dir)
        let back = MeetingFiles.readSegments(dir)
        #expect(back.map(\.text) == ["Hello", "Hi"])
        #expect(back[0].start == 1.23) // rounded to 10 ms in the file
        let json = try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8)
        #expect(json.contains("\"speaker\" : \"Me\""))
        let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(md.contains("**Me:** Hello"))
    }

    @Test func lenientInfo() throws {
        let json = #"{"startedAt":"2026-11-25T08:32:00Z","status":"something-new","title":"X"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let info = try d.decode(MeetingInfo.self, from: Data(json.utf8))
        #expect(info.status == .failed && info.title == "X" && info.wordCount == 0)
    }

    @Test func transcriptValidity() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MeetingFiles.readTranscript(dir) == nil)
        try MeetingFiles.writeTranscript([], info: MeetingInfo(title: "X", startedAt: Date()), to: dir)
        #expect(MeetingFiles.readTranscript(dir) == []) // written, even if nobody spoke
        try Data("{".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        #expect(MeetingFiles.readTranscript(dir) == nil)
    }

    @Test func recoveredInfoFollowsTheSavedStatus() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = MeetingInfo(title: "X", startedAt: Date(), status: .transcribing)
        #expect(MeetingFiles.recoveredInfo(base, folder: dir, keepAudio: false) == nil)
        for (saved, expected, kept) in [(MeetingInfo.Status.ready, MeetingInfo.Status.ready, false), (.partial, .partial, true), (.failed, .failed, true)] {
            var i = base
            i.status = saved
            try MeetingFiles.writeTranscript([seg(0, 1, .me, "one two three")], info: i, to: dir)
            let r = try #require(MeetingFiles.recoveredInfo(base, folder: dir, keepAudio: false))
            #expect(r.info.status == expected && r.info.audioKept == kept && r.info.wordCount == 3)
        }
        // A file without a status (or an odd one) is not trusted with the audio.
        let file = MeetingFiles.TranscriptFile(status: nil, segments: [seg(0, 1, .me, "hi")])
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("transcript.json"))
        let r = try #require(MeetingFiles.recoveredInfo(base, folder: dir, keepAudio: false))
        #expect(r.info.status == .partial && r.info.audioKept)
        #expect(MeetingFiles.readTranscriptFile(dir)?.status == nil)
    }

    @Test func audioFilesAndDelete() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("mic.wav"))
        #expect(MeetingFiles.audioFiles(dir).map(\.lastPathComponent) == ["mic.wav"])
        MeetingFiles.deleteAudio(dir)
        #expect(MeetingFiles.audioFiles(dir).isEmpty)
    }
}

@Suite struct MeetingAudioTests {
    func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString).wav") }

    @Test func wavHeader() {
        let h = WAV.header(dataBytes: 32000)
        #expect(h.count == 44)
        #expect(WAV.isOurs(h))
        #expect(Array(h[4..<8]) == [0x24, 0x7D, 0, 0]) // 36 + 32000, little-endian
        #expect(Array(h[24..<28]) == [0x80, 0x3E, 0, 0]) // 16000 Hz
        #expect(!WAV.isOurs(Data(repeating: 0, count: 44)))
    }

    @Test func int16Conversion() {
        #expect(WAV.int16(0) == 0)
        #expect(WAV.int16(1) == 32767)
        #expect(WAV.int16(-2) == -32767)
        #expect(WAV.int16(0.5) == 16384)
    }

    @Test func writeReadAndRepair() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try WavWriter(url: url)
        let tone = (0..<20_000).map { sinf(Float($0) * 0.05) * 0.5 }
        try w.append(tone)
        try w.appendSilence(1000)
        #expect(w.sampleCount == 21_000)
        #expect(WavReader(url: url.appendingPathExtension("missing")) == nil)
        // Readable while still being written (header sizes may lag).
        #expect(WavReader.sampleCount(url) == 21_000)
        let back = WavReader.read(url, 100..<200)
        #expect(back.count == 100)
        #expect(zip(back, tone[100..<200]).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(WavReader.read(url, 20_500..<30_000).allSatisfy { $0 == 0 }) // clipped to the file
        // One reader, many reads, while the file keeps growing.
        let reader = try #require(WavReader(url: url))
        try w.append([0.25])
        #expect(reader.sampleCount == 21_001)
        #expect(abs((reader.read(21_000..<21_001).first ?? 0) - 0.25) < 1e-4)
        #expect(WavReader.read(url, 20_500..<30_000).count == 501)
        w.close()
        let header = try Data(contentsOf: url).prefix(44)
        #expect(header == WAV.header(dataBytes: 42_002))

        // A crash leaves the last header patch behind: repair recomputes it from the size.
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: 0)
        try h.write(contentsOf: WAV.header(dataBytes: 0))
        try h.close()
        WavReader.repairHeader(url)
        #expect(try Data(contentsOf: url).prefix(44) == WAV.header(dataBytes: 42_002))
    }

    @Test func readerRejectsOtherFiles() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 1000).write(to: url)
        #expect(WavReader.sampleCount(url) == 0)
        #expect(WavReader.read(url, 0..<10).isEmpty)
    }

    @Test func aligner() {
        let a = ChannelAligner(tolerance: 4000)
        #expect(a.gap(written: 16_000, expected: 16_500) == 0)    // jitter
        #expect(a.gap(written: 16_000, expected: 48_000) == 32_000) // device restarted 2 s later
        #expect(a.gap(written: 50_000, expected: 48_000) == 0)    // running ahead: never drop audio
        #expect(a.gap(written: 16_000, expected: 16_500, exact: true) == 500) // first buffer after a (re)start
        #expect(a.gap(written: 16_000, expected: 15_000, exact: true) == 0)
        #expect(a.gap(written: 0, expected: Int.max / 2) == ChannelAligner.maxGap) // a bad timestamp can't allocate gigabytes
        #expect(ChannelAligner.position(nanosSinceStart: 2_500_000_000) == 40_000)
        #expect(ChannelAligner.position(nanosSinceStart: 3 * 3600 * 1_000_000_000) == 3 * 3600 * 16_000)
    }

    @Test func liveChunkerMatchesBatchPlan() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var segments: [Segment] = []
            var t = Int.random(in: 0..<8000, using: &rng)
            for _ in 0..<Int.random(in: 0..<25, using: &rng) {
                let len = Int.random(in: 1600..<(sampleRate * 8), using: &rng)
                segments.append(Segment(start: t, length: len))
                t += len + Int.random(in: 8000..<(sampleRate * 6), using: &rng) // VAD needs 0.5 s of silence between
            }
            let total = t + Int.random(in: 0..<8000, using: &rng)
            for maxChunk in [AudioChunker.maxChunk, WhisperBudget.maxChunkSamples] {
                var live = LiveChunker(maxChunk: maxChunk)
                var ranges: [Range<Int>] = []
                for s in segments {
                    ranges += live.flush(position: s.start).map(\.range)
                    ranges += live.add(s).map(\.range)
                }
                ranges += live.finish(total: total).map(\.range)
                #expect(ranges == AudioChunker.plan(total: total, segments: segments, maxChunk: maxChunk))
            }
        }
    }

    @Test func liveChunkerHandsOutAChunkAfterAPause() {
        var c = LiveChunker()
        #expect(c.add(Segment(start: 16_000, length: 32_000)).isEmpty)
        #expect(c.flush(position: 50_000).isEmpty) // could still merge
        #expect(c.flush(position: 52_000 + AudioChunker.maxMergeGap).isEmpty) // a segment starting now might still join
        let out = c.flush(position: 52_000 + AudioChunker.maxMergeGap + AudioChunker.pad + LiveChunker.lookback)
        #expect(out == [ChunkPlan(range: 12_000..<52_000, speech: [16_000..<48_000])])
        #expect(out[0].speechSamples == 32_000 && out[0].speechInChunk == [4000..<36_000])
        #expect(c.finish(total: 100_000).isEmpty)
    }

    @Test func liveChunkerSpeechPerChunk() {
        var c = LiveChunker()
        _ = c.add(Segment(start: 0, length: 16_000))
        _ = c.add(Segment(start: 20_000, length: 16_000))
        #expect(c.finish(total: 40_000) == [ChunkPlan(range: 0..<40_000, speech: [0..<16_000, 20_000..<36_000])])
        // A segment longer than a chunk is split, and so is its speech.
        var long = LiveChunker(maxChunk: 10_000)
        _ = long.add(Segment(start: 0, length: 15_000))
        #expect(long.finish(total: 30_000).map(\.speechSamples) == [10_000, 5000])
    }

    @Test func levels() {
        #expect(AudioLevel.rms([]) == 0)
        #expect(abs(AudioLevel.rms([0.5, -0.5]) - 0.5) < 1e-6)
        #expect(AudioLevel.peak([0.1, -0.7, 0.3]) == 0.7)
        #expect(AudioLevel.meter(0) == 0)
        #expect(AudioLevel.meter(1) == 1)
        #expect(AudioLevel.isNearSilent([Float](repeating: 0.001, count: 100)))
        #expect(!AudioLevel.isNearSilent([Float](repeating: 0.05, count: 100)))
        // A short quiet sentence in a chunk that is mostly silence: judged on the speech only.
        let chunk = [Float](repeating: 0, count: 9000) + [Float](repeating: 0.004, count: 1000)
        #expect(AudioLevel.isNearSilent(chunk))
        #expect(!AudioLevel.isNearSilent(chunk, speech: [9000..<10_000]))
        #expect(AudioLevel.isNearSilent(chunk, speech: []))
    }

    @Test func silenceWatch() {
        var w = SilenceWatch(afterSeconds: 2)
        #expect(w.feed(peak: 0, count: 16_000) == nil)
        #expect(w.feed(peak: 0, count: 16_000) == .silent)
        #expect(w.feed(peak: 0, count: 16_000) == nil)
        #expect(w.feed(peak: 0.01, count: 160) == .sound) // permission turned on, or a call started
        #expect(w.feed(peak: 0, count: 100_000) == nil)     // later pauses are normal
        #expect(w.state == .sound)
    }

    @Test func downmix() {
        let stereo: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        stereo.withUnsafeBufferPointer {
            #expect(Downmix.average($0, channels: 2) == [0.5, 0.5, 0])
            #expect(Downmix.first($0, channels: 2) == [1, 0.5, -1])
            #expect(Downmix.average($0, channels: 1) == stereo)
        }
        #expect(Downmix.tailBuffers(channelCounts: [2], wanted: 2) == 0..<1)
        #expect(Downmix.tailBuffers(channelCounts: [1, 1], wanted: 2) == 0..<2)
        #expect(Downmix.tailBuffers(channelCounts: [1, 2], wanted: 2) == 1..<2) // headset mic first, tap last
        #expect(Downmix.tailBuffers(channelCounts: [1], wanted: 2) == nil)
        #expect(Downmix.tailBuffers(channelCounts: [], wanted: 2) == nil)
    }

    @Test func meetingLimit() {
        var l = MeetingLimit(minutes: 30)
        #expect(l.check(elapsed: 60) == nil)
        #expect(l.check(elapsed: 25 * 60) == .warn(minutesLeft: 5))
        #expect(l.check(elapsed: 26 * 60) == nil) // warned once
        #expect(l.check(elapsed: 30 * 60) == .stop)
        #expect(MeetingLimit.looksAccidental(words: 19, seconds: 30))
        #expect(!MeetingLimit.looksAccidental(words: 20, seconds: 30))
        #expect(!MeetingLimit.looksAccidental(words: 3, seconds: 45 * 60)) // a long call where I only listened
        #expect(MeetingLimit.title(30) == "30 min" && MeetingLimit.title(60) == "1 hour" && MeetingLimit.title(180) == "3 hours")
    }

    @Test func diskSpace() {
        #expect(DiskSpace.bytesPerMinute == 3_840_000)
        #expect(DiskSpace.level(freeBytes: 100_000_000_000) == .ok)
        #expect(DiskSpace.level(freeBytes: DiskSpace.reserve + 30 * DiskSpace.bytesPerMinute) == .low(minutesLeft: 30))
        #expect(DiskSpace.level(freeBytes: DiskSpace.reserve + DiskSpace.bytesPerMinute) == .critical)
        #expect(DiskSpace.level(freeBytes: 0) == .critical)
    }
}

@Suite struct DequeTests {
    @Test func fifoWithRetriesAtTheFront() {
        var q = Deque<Int>()
        #expect(q.isEmpty && q.popFirst() == nil)
        q.append(contentsOf: Array(1...200))
        for i in 1...150 { #expect(q.popFirst() == i) }
        q.pushFront(150) // retry
        #expect(q.count == 51)
        #expect(q.popFirst() == 150)
        q.append(201)
        var rest: [Int] = []
        while let x = q.popFirst() { rest.append(x) }
        #expect(rest == Array(151...201))
        q.pushFront(7)
        #expect(q.popFirst() == 7 && q.isEmpty)
    }
}
