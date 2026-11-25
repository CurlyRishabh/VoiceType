import Foundation
import Testing
@testable import VoiceTypeCore

@Suite struct MeetingNotesTests {
    let segs = [
        TranscriptSegment(start: 0, end: 4, channel: .me, text: "Hello all."),
        TranscriptSegment(start: 30, end: 34, channel: .others, text: "Hi, let's begin."),
    ]

    @Test func notesInterleaveByTime() {
        let lines = MeetingTranscript.lines(segs, notes: [MeetingNote(at: 10, text: "ask about budget"), MeetingNote(at: 99, text: "follow up")])
        #expect(lines.map(\.label) == ["Me", "My note", "Others", "My note"])
        #expect(lines.map(\.id) == [0, 1, 2, 3])
        #expect(lines[1].isNote && lines[1].start == 10)
    }

    @Test func blankNotesDropped() {
        #expect(MeetingTranscript.lines(segs, notes: [MeetingNote(at: 5, text: "  ")]).count == 2)
    }

    @Test func noteAtSameTimeGoesAfterSpeech() {
        let lines = MeetingTranscript.lines(segs, notes: [MeetingNote(at: 30, text: "x")])
        #expect(lines.map(\.label) == ["Me", "Others", "My note"])
    }

    @Test func markdownHasNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try MeetingFiles.writeNotes([MeetingNote(at: 12, text: "Decide owner")], to: dir)
        #expect(MeetingFiles.readNotes(dir) == [MeetingNote(at: 12, text: "Decide owner")])
        var info = MeetingInfo(title: "T", startedAt: Date(timeIntervalSince1970: 0), status: .ready)
        info.durationSeconds = 40
        try MeetingFiles.writeTranscript(segs, info: info, to: dir)
        let md = try String(contentsOf: dir.appendingPathComponent(MeetingFiles.transcriptMarkdown), encoding: .utf8)
        #expect(md.contains("[00:00:12] 📝 **My note:** Decide owner"))
        #expect(md.contains("My note"))
    }
}

@Suite struct AudioRetentionTests {
    func info(_ status: MeetingInfo.Status, endedDaysAgo: Double, kept: Bool = true) -> MeetingInfo {
        var i = MeetingInfo(title: "T", startedAt: Date(timeIntervalSince1970: 0), status: status)
        i.endedAt = Date(timeIntervalSince1970: 1_000_000 - endedDaysAgo * 86_400)
        i.audioKept = kept
        return i
    }
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func readyExpiresAfterDays() {
        #expect(!AudioRetention.expired(info(.ready, endedDaysAgo: 6), days: 7, now: now))
        #expect(AudioRetention.expired(info(.ready, endedDaysAgo: 7), days: 7, now: now))
        #expect(AudioRetention.expired(info(.ready, endedDaysAgo: 0), days: 0, now: now))
    }

    @Test func foreverAndNoAudioNeverExpire() {
        #expect(!AudioRetention.expired(info(.ready, endedDaysAgo: 900), days: -1, now: now))
        #expect(!AudioRetention.expired(info(.ready, endedDaysAgo: 900, kept: false), days: 1, now: now))
    }

    @Test func liveMeetingsNeverExpire() {
        #expect(!AudioRetention.expired(info(.recording, endedDaysAgo: 30), days: 1, now: now))
        #expect(!AudioRetention.expired(info(.transcribing, endedDaysAgo: 30), days: 1, now: now))
    }

    @Test func partialKeepsAtLeastDefault() {
        #expect(!AudioRetention.expired(info(.partial, endedDaysAgo: 3), days: 0, now: now))
        #expect(AudioRetention.expired(info(.partial, endedDaysAgo: 7), days: 0, now: now))
        #expect(!AudioRetention.expired(info(.failed, endedDaysAgo: 10), days: 30, now: now))
    }
}

@Suite struct CallDetectionTests {
    let zoom = CallApps.app(bundleID: "us.zoom.xos")!
    let chrome = CallApps.app(bundleID: "com.google.Chrome.helper")!

    @Test func knownApps() {
        #expect(zoom.meetingTitle == "Zoom call")
        #expect(chrome.isBrowser)
        #expect(CallApps.app(bundleID: "com.microsoft.teams2")?.name == "Microsoft Teams")
        #expect(CallApps.app(bundleID: "com.tinyspeck.slackmacgap")?.meetingTitle == "Slack huddle")
        #expect(CallApps.app(bundleID: "com.apple.VoiceMemos") == nil)
        #expect(CallApps.app(bundleID: "dev.offline.voicetype.mac") == nil)
    }

    @Test func startsAfterHoldingTheMic() {
        var w = CallWatch(startAfter: 6, endAfter: 20)
        #expect(w.feed([zoom], now: 0) == nil)
        #expect(w.feed([zoom], now: 4) == nil)
        #expect(w.feed([zoom], now: 6) == .started(zoom))
        #expect(w.feed([zoom], now: 8) == nil) // once
    }

    @Test func shortUseIsNotACall() {
        var w = CallWatch(startAfter: 6, endAfter: 20)
        _ = w.feed([zoom], now: 0)
        _ = w.feed([], now: 3)
        #expect(w.feed([zoom], now: 6) == nil) // the clock restarted at 6
        #expect(w.feed([zoom], now: 12) == .started(zoom))
    }

    @Test func endsAfterQuietPeriod() {
        var w = CallWatch(startAfter: 6, endAfter: 20)
        _ = w.feed([zoom], now: 0)
        _ = w.feed([zoom], now: 6)
        #expect(w.feed([], now: 10) == nil)
        #expect(w.feed([], now: 25) == nil)
        #expect(w.feed([], now: 26) == .ended(zoom))
        #expect(w.active == nil)
    }

    @Test func briefDropDoesNotEnd() {
        var w = CallWatch(startAfter: 6, endAfter: 20)
        _ = w.feed([zoom], now: 0)
        _ = w.feed([zoom], now: 6)
        _ = w.feed([], now: 10)
        #expect(w.feed([zoom], now: 20) == nil)
        #expect(w.feed([], now: 35) == nil)
        #expect(w.feed([], now: 40) == .ended(zoom))
    }

    @Test func nativeAppBeatsBrowser() {
        var w = CallWatch(startAfter: 6, endAfter: 20)
        _ = w.feed([chrome, zoom], now: 0)
        #expect(w.feed([chrome, zoom], now: 6) == .started(zoom))
    }
}
