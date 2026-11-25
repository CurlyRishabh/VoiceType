import Foundation

/// A stretch of audio the speaker diarizer gave to one voice (seconds, on its own timeline).
public struct SpeakerTurn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int
    public init(start: Double, end: Double, speaker: Int) { self.start = start; self.end = end; self.speaker = speaker }
}

/// Telling the other people on a call apart. Only the system-audio channel is analysed, and only
/// where the transcript says someone spoke: those stretches are cut out and joined (`Timeline`), so
/// an hour-long call with long silences costs a fraction of an hour, and the diarizer's times are
/// mapped back. Each Others segment then gets the voice that overlaps it most.
public enum SpeakerAssign {
    /// Others' speech as stretches of the original audio: segment spans padded and merged.
    public struct Timeline: Equatable, Sendable {
        /// Original-time ranges, in order, not overlapping.
        public let ranges: [ClosedRange<Double>]

        public init(_ segments: [TranscriptSegment], pad: Double = 0.3, total: Double) {
            // Bounds first, ranges only when valid (a segment past the end of a cut-short file).
            let spans = segments.filter { $0.channel == .others && $0.end > $0.start }
                .map { (max(0, $0.start - pad), min(total, $0.end + pad)) }
                .filter { $0.1 > $0.0 }
                .map { $0.0...$0.1 }
                .sorted { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<Double>] = []
            for r in spans {
                if let last = merged.last, r.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
                } else {
                    merged.append(r)
                }
            }
            ranges = merged
        }

        /// Seconds of audio the diarizer gets.
        public var length: Double { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

        /// A time on the joined timeline → the original meeting time.
        public func original(_ t: Double) -> Double {
            var offset = 0.0
            for r in ranges {
                let len = r.upperBound - r.lowerBound
                if t <= offset + len { return r.lowerBound + max(0, t - offset) }
                offset += len
            }
            return ranges.last?.upperBound ?? t
        }

        /// Turns on the joined timeline → original time (a turn that spans a join is split there).
        public func original(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
            var out: [SpeakerTurn] = []
            var offset = 0.0
            for r in ranges {
                let len = r.upperBound - r.lowerBound
                for t in turns where t.end > offset && t.start < offset + len {
                    let s = max(t.start, offset) - offset, e = min(t.end, offset + len) - offset
                    out.append(SpeakerTurn(start: r.lowerBound + s, end: r.lowerBound + e, speaker: t.speaker))
                }
                offset += len
            }
            return out
        }
    }

    /// Gives each Others segment the voice it overlaps most (or the nearest one within 2 s).
    /// Voices are numbered 1, 2… in order of first appearance. With fewer than two voices nothing is
    /// labelled (it stays "Others"). Returns the segments and how many voices were found.
    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> (segments: [TranscriptSegment], speakers: Int) {
        var raw: [Int?] = segments.map { s in
            guard s.channel == .others else { return nil }
            var best: (Int, Double)?
            for t in turns {
                let overlap = min(s.end, t.end) - max(s.start, t.start)
                if overlap > 0, overlap > (best?.1 ?? 0) { best = (t.speaker, overlap) }
            }
            if let best { return best.0 }
            let mid = (s.start + s.end) / 2
            let near = turns.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }
            guard let near, min(abs(near.start - s.end), abs(s.start - near.end)) <= 2 else { return nil }
            return near.speaker
        }
        // Renumber by first appearance in time.
        var order: [Int: Int] = [:]
        for i in segments.indices.sorted(by: { segments[$0].start < segments[$1].start }) {
            if let r = raw[i], order[r] == nil { order[r] = order.count + 1 }
        }
        guard order.count >= 2 else {
            return (segments.map { var s = $0; s.voice = nil; return s }, order.count)
        }
        raw = raw.map { $0.flatMap { order[$0] } }
        var out = segments
        for i in out.indices { out[i].voice = raw[i] }
        return (out, order.count)
    }
}
