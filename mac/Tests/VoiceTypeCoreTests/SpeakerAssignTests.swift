import Foundation
import Testing
@testable import VoiceTypeCore

@Suite struct SpeakerAssignTests {
    func o(_ s: Double, _ e: Double, _ t: String = "x") -> TranscriptSegment { TranscriptSegment(start: s, end: e, channel: .others, text: t) }

    @Test func timelineJoinsSpeechAndMapsBack() {
        let tl = SpeakerAssign.Timeline([o(10, 12), o(11.5, 14), o(30, 31)], pad: 0, total: 60)
        #expect(tl.ranges == [10...14, 30...31])
        #expect(tl.length == 5)
        #expect(tl.original(0) == 10)
        #expect(tl.original(4.5) == 30.5)
        let turns = tl.original([SpeakerTurn(start: 3, end: 5, speaker: 7)]) // spans the join
        #expect(turns == [SpeakerTurn(start: 13, end: 14, speaker: 7), SpeakerTurn(start: 30, end: 31, speaker: 7)])
    }

    @Test func meIsIgnored() {
        let tl = SpeakerAssign.Timeline([TranscriptSegment(start: 0, end: 5, channel: .me, text: "hi")], total: 10)
        #expect(tl.ranges.isEmpty)
    }

    @Test func assignsByOverlapAndNumbersInOrder() {
        let segs = [o(0, 4), TranscriptSegment(start: 2, end: 3, channel: .me, text: "me"), o(5, 9), o(10, 12)]
        let turns = [SpeakerTurn(start: 0, end: 4.5, speaker: 5), SpeakerTurn(start: 4.5, end: 9.5, speaker: 2), SpeakerTurn(start: 10, end: 12, speaker: 5)]
        let (out, n) = SpeakerAssign.assign(segs, turns: turns)
        #expect(n == 2)
        #expect(out.map(\.voice) == [1, nil, 2, 1])
    }

    @Test func oneVoiceStaysOthers() {
        let (out, n) = SpeakerAssign.assign([o(0, 2), o(3, 5)], turns: [SpeakerTurn(start: 0, end: 5, speaker: 0)])
        #expect(n == 1)
        #expect(out.allSatisfy { $0.voice == nil })
    }

    @Test func nearestTurnWithinTwoSeconds() {
        let (out, _) = SpeakerAssign.assign([o(0, 2), o(6, 7), o(30, 31)],
                                            turns: [SpeakerTurn(start: 0, end: 2, speaker: 0), SpeakerTurn(start: 8, end: 9, speaker: 1)])
        #expect(out.map(\.voice) == [1, 2, nil])
    }

    @Test func linesSplitByVoiceAndUseNames() {
        var a = o(0, 2, "Hello."), b = o(2.5, 4, "Hi there.")
        a.voice = 1; b.voice = 2
        let lines = MeetingTranscript.lines([a, b], names: [2: "Priya"])
        #expect(lines.map(\.label) == ["Speaker 1", "Priya"])
    }

    @Test func voiceRoundTripsInJSON() throws {
        var s = o(1, 2, "Yes")
        s.voice = 3
        let data = try JSONEncoder().encode(s)
        #expect(String(decoding: data, as: UTF8.self).contains("\"speaker\":\"Speaker 3\""))
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: data).voice == 3)
    }

    @Test func headerListsNamedSpeakers() {
        var info = MeetingInfo(title: "T", startedAt: Date(timeIntervalSince1970: 0), status: .ready)
        info.speakers = 2
        info.speakerNames = ["1": "Rishabh"]
        let h = MeetingRender.header(info, timeZone: TimeZone(identifier: "UTC")!)
        #expect(h.contains("Rishabh (Speaker 1), Speaker 2"))
    }
}
