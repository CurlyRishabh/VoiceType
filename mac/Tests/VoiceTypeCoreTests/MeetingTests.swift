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
    }

    @Test func toleratesMisheardWords() {
        // Whisper on the faint echo misses or changes a word or two.
        #expect(EchoFilter.isEcho("the deploy is blocked on the database migration",
                                  of: "The deploy is blocked on the DB migration, sorry."))
    }

    @Test func lcs() {
        #expect(EchoFilter.commonSubsequence(["a", "b", "c", "d"], ["a", "c", "d", "e"]) == 3)
        #expect(EchoFilter.commonSubsequence([], ["a"]) == 0)
    }
}

@Suite struct MeetingTextFilterTests {
    func t(_ text: String, _ s: Double = 0, _ e: Double = 2) -> TimedText { TimedText(text: text, start: s, end: e) }

    @Test func dropsNearSilencePhrasesPerChunk() {
        #expect(MeetingTextFilter.clean([t("Thank you for watching!")], speechMillis: 600, previous: nil).isEmpty)
        #expect(MeetingTextFilter.clean([t("You")], speechMillis: 400, previous: nil).isEmpty)
        // Real speech with the same words is kept.
        #expect(MeetingTextFilter.clean([t("Thank you.")], speechMillis: 900, previous: nil).map(\.text) == ["Thank you."])
    }

    @Test func stripsTagsAndLoops() {
        let out = MeetingTextFilter.clean([t("[Music]"), t("go go go go go now", 2, 4)], speechMillis: 4000, previous: nil)
        #expect(out == [t("go now", 2, 4)])
    }

    @Test func collapsesRepeatedSegmentsInAChunk() {
        let out = MeetingTextFilter.clean([t("Let's start.", 0, 2), t("let's start", 2, 4), t("Agenda first.", 4, 6)], speechMillis: 6000, previous: nil)
        #expect(out.map(\.text) == ["Let's start.", "Agenda first."])
        #expect(out[0].end == 4)
    }

    @Test func dropsAChunkThatRepeatsThePreviousOne() {
        #expect(MeetingTextFilter.clean([t("Please hold, your call is important to us.")], speechMillis: 5000,
                                        previous: "please hold your call is important to us").isEmpty)
        #expect(MeetingTextFilter.clean([t("New words.")], speechMillis: 5000, previous: "Old words.").count == 1)
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
        // Readable while still being written (header sizes may lag).
        #expect(WavReader.sampleCount(url) == 21_000)
        let back = WavReader.read(url, 100..<200)
        #expect(back.count == 100)
        #expect(zip(back, tone[100..<200]).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(WavReader.read(url, 20_500..<30_000).allSatisfy { $0 == 0 }) // clipped to the file
        #expect(WavReader.read(url, 20_500..<30_000).count == 500)
        w.close()
        let header = try Data(contentsOf: url).prefix(44)
        #expect(header == WAV.header(dataBytes: 42_000))

        // A crash leaves the last header patch behind: repair recomputes it from the size.
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: 0)
        try h.write(contentsOf: WAV.header(dataBytes: 0))
        try h.close()
        WavReader.repairHeader(url)
        #expect(try Data(contentsOf: url).prefix(44) == WAV.header(dataBytes: 42_000))
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
        #expect(out == [ChunkPlan(range: 12_000..<52_000, speechSamples: 32_000)])
        #expect(c.finish(total: 100_000).isEmpty)
    }

    @Test func liveChunkerSpeechPerChunk() {
        var c = LiveChunker()
        _ = c.add(Segment(start: 0, length: 16_000))
        _ = c.add(Segment(start: 20_000, length: 16_000))
        #expect(c.finish(total: 40_000) == [ChunkPlan(range: 0..<40_000, speechSamples: 32_000)])
    }

    @Test func levels() {
        #expect(AudioLevel.rms([]) == 0)
        #expect(abs(AudioLevel.rms([0.5, -0.5]) - 0.5) < 1e-6)
        #expect(AudioLevel.peak([0.1, -0.7, 0.3]) == 0.7)
        #expect(AudioLevel.meter(0) == 0)
        #expect(AudioLevel.meter(1) == 1)
        #expect(AudioLevel.isNearSilent([Float](repeating: 0.001, count: 100)))
        #expect(!AudioLevel.isNearSilent([Float](repeating: 0.05, count: 100)))
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
        #expect(MeetingLimit.looksAccidental(words: 19))
        #expect(!MeetingLimit.looksAccidental(words: 20))
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
