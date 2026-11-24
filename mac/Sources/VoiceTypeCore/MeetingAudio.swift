import Foundation

/// 16-bit PCM WAV, mono, 16 kHz: the meeting's audio on disk. Written as it records, so a crash,
/// sleep or quit loses nothing, and read back a chunk at a time, so a long meeting never sits in RAM.
public enum WAV {
    public static let headerSize = 44
    public static let bytesPerSample = 2

    /// The canonical 44-byte header for `dataBytes` of audio.
    public static func header(dataBytes: Int, sampleRate: Int = sampleRate) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                                   // PCM
        u16(1)                                   // mono
        u32(sampleRate)
        u32(sampleRate * bytesPerSample)         // byte rate
        u16(bytesPerSample)                      // block align
        u16(bytesPerSample * 8)                  // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// True for the header this file format writes (sizes not checked: after a crash they lag behind).
    public static func isOurs(_ header: Data) -> Bool {
        guard header.count >= headerSize else { return false }
        let h = [UInt8](header.prefix(headerSize))
        return h[0..<4] == Array("RIFF".utf8)[...] && h[8..<16] == Array("WAVEfmt ".utf8)[...]
            && h[20] == 1 && h[22] == 1 && h[34] == 16 && h[36..<40] == Array("data".utf8)[...]
    }

    public static func int16(_ v: Float) -> Int16 { Int16((max(-1, min(1, v)) * 32767).rounded()) }
}

/// Appends audio to a WAV file. The header's sizes are patched every few seconds and on close, so a
/// file cut off by a crash is still readable (and `WavReader.repairHeader` fixes it exactly).
/// Not thread-safe: one queue writes.
public final class WavWriter {
    public let url: URL
    public private(set) var sampleCount = 0
    private var fd: Int32
    private var sinceHeader = 0
    private static let headerEvery = sampleRate * 5

    public init(url: URL) throws {
        self.url = url
        fd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        try put(WAV.header(dataBytes: 0), at: 0)
    }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, fd >= 0 else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = WAV.int16(samples[i]).littleEndian }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        try put(data, at: WAV.headerSize + sampleCount * WAV.bytesPerSample)
        sampleCount += samples.count
        sinceHeader += samples.count
        if sinceHeader >= Self.headerEvery {
            sinceHeader = 0
            try? put(WAV.header(dataBytes: sampleCount * WAV.bytesPerSample), at: 0)
            fsync(fd) // a power cut loses at most these few seconds
        }
    }

    /// Writes `count` samples of silence.
    public func appendSilence(_ count: Int) throws {
        var left = count
        while left > 0 {
            let n = min(left, sampleRate)
            try append([Float](repeating: 0, count: n))
            left -= n
        }
    }

    /// Final header, flushed to disk. Safe to call twice.
    public func close() {
        guard fd >= 0 else { return }
        try? put(WAV.header(dataBytes: sampleCount * WAV.bytesPerSample), at: 0)
        fsync(fd)
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }

    private func put(_ data: Data, at offset: Int) throws {
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}

/// Reads back what `WavWriter` wrote (including a file still being written). One open file for
/// all reads: a meeting reads a chunk every few seconds.
public final class WavReader {
    public let url: URL
    private let fd: Int32

    /// nil when the file is missing or isn't one of ours.
    public init?(url: URL) {
        self.url = url
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var header = [UInt8](repeating: 0, count: WAV.headerSize)
        let n = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress, WAV.headerSize, 0) }
        guard n == WAV.headerSize, WAV.isOurs(Data(header)) else { Darwin.close(fd); return nil }
    }

    deinit { Darwin.close(fd) }

    /// Samples in the file, from its size (the header may lag behind while recording or after a crash).
    public var sampleCount: Int {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        return max(0, Int(st.st_size) - WAV.headerSize) / WAV.bytesPerSample
    }

    /// Samples in `range` (clipped to the file) as Float32.
    public func read(_ range: Range<Int>) -> [Float] {
        let r = max(0, range.lowerBound)..<min(sampleCount, range.upperBound)
        guard !r.isEmpty else { return [] }
        var pcm = [Int16](repeating: 0, count: r.count)
        let bytes = pcm.withUnsafeMutableBytes { pread(fd, $0.baseAddress, r.count * WAV.bytesPerSample, off_t(WAV.headerSize + r.lowerBound * WAV.bytesPerSample)) }
        guard bytes > 0 else { return [] }
        return pcm.prefix(bytes / WAV.bytesPerSample).map { Float(Int16(littleEndian: $0)) / 32767 }
    }

    public static func sampleCount(_ url: URL) -> Int { WavReader(url: url)?.sampleCount ?? 0 }

    public static func read(_ url: URL, _ range: Range<Int>) -> [Float] { WavReader(url: url)?.read(range) ?? [] }

    /// Rewrites the header's sizes from the file size (a recording cut off by a crash).
    public static func repairHeader(_ url: URL) {
        let count = sampleCount(url)
        guard count > 0, let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: 0)
        try? h.write(contentsOf: WAV.header(dataBytes: count * WAV.bytesPerSample))
    }
}

/// Keeps a channel on the meeting's clock. Each buffer says when it was captured; when it arrives
/// later than the samples already written account for (the device started late, restarted after a
/// device change, or dropped buffers), the gap is filled with silence so Me and Others share one
/// timeline. Jitter and clock drift below `tolerance` are ignored (a device clock off by 50 ppm
/// drifts a second in 5½ hours; padding for it would put silence in the middle of words), and audio
/// is never dropped.
public struct ChannelAligner: Sendable {
    public let tolerance: Int
    /// A gap longer than this is a bad timestamp, not a pause in the audio (the meeting stops on
    /// sleep, and device switches take seconds).
    public static let maxGap = sampleRate * 120

    public init(tolerance: Int = sampleRate) { self.tolerance = tolerance }

    /// Silence to write before a buffer captured at `expected` (samples since the meeting started).
    /// `exact`: the first buffer after the capture (re)started, when the gap is a real one and is
    /// filled to the sample.
    public func gap(written: Int, expected: Int, exact: Bool = false) -> Int {
        let g = expected - written
        guard g > (exact ? 0 : tolerance) else { return 0 }
        return min(g, Self.maxGap)
    }

    /// Host-clock nanoseconds since the start -> sample position.
    public static func position(nanosSinceStart: UInt64) -> Int { Int(nanosSinceStart / 1000 * UInt64(sampleRate) / 1_000_000) }
}

/// A decode chunk and where the VAD found speech in it.
public struct ChunkPlan: Equatable, Sendable {
    public let range: Range<Int>
    /// The VAD segments inside `range` (absolute sample positions).
    public let speech: [Range<Int>]
    public init(range: Range<Int>, speech: [Range<Int>]) { self.range = range; self.speech = speech }

    public var speechSamples: Int { speech.reduce(0) { $0 + $1.count } }

    /// `speech` relative to the start of the chunk.
    public var speechInChunk: [Range<Int>] { speech.map { ($0.lowerBound - range.lowerBound)..<($0.upperBound - range.lowerBound) } }
}

/// `AudioChunker.plan`, one VAD segment at a time, for audio that is still being recorded: the same
/// padding, merging (gaps under 3 s) and length cap, but a chunk is handed out as soon as no later
/// speech can join it, so it is transcribed while the meeting goes on.
public struct LiveChunker: Sendable {
    public let maxChunk: Int
    private var current: Range<Int>?
    private var speech: [Range<Int>] = []

    public init(maxChunk: Int = AudioChunker.maxChunk) { self.maxChunk = maxChunk }

    /// A finished VAD segment. Returns the chunks it closes.
    public mutating func add(_ s: Segment) -> [ChunkPlan] {
        let r = max(0, s.start - AudioChunker.pad)..<(s.end + AudioChunker.pad)
        guard !r.isEmpty else { return [] }
        if let c = current, r.lowerBound - c.upperBound < AudioChunker.maxMergeGap, r.upperBound - c.lowerBound <= maxChunk {
            current = c.lowerBound..<max(c.upperBound, r.upperBound)
            speech.append(s.start..<s.end)
            return []
        }
        let closed = close(total: nil)
        current = r
        speech = [s.start..<s.end]
        return closed
    }

    /// How far back the VAD dates a segment's start from the moment it hears speech (its minimum
    /// speech length plus a window), with margin.
    public static let lookback = sampleRate / 2

    /// Recording has reached `position` and the VAD hears no speech right now: a chunk that no later
    /// segment can join any more is closed. (While someone talks, the segment in progress may still
    /// join it, so don't call this then.)
    public mutating func flush(position: Int) -> [ChunkPlan] {
        guard let c = current, position - c.upperBound >= AudioChunker.maxMergeGap + AudioChunker.pad + Self.lookback else { return [] }
        return close(total: nil)
    }

    /// The recording ended at `total` samples: everything left.
    public mutating func finish(total: Int) -> [ChunkPlan] { close(total: total) }

    private mutating func close(total: Int?) -> [ChunkPlan] {
        guard let c = current else { return [] }
        current = nil
        let r = c.lowerBound..<min(total ?? c.upperBound, c.upperBound)
        guard !r.isEmpty else { return [] }
        let speech = self.speech
        return AudioChunker.split(r, maxChunk).map { piece in
            ChunkPlan(range: piece, speech: speech.compactMap { s in s.clamped(to: piece).isEmpty ? nil : s.clamped(to: piece) })
        }
    }
}

public enum AudioLevel {
    public static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }

    public static func peak(_ s: [Float]) -> Float { s.reduce(0) { max($0, abs($1)) } }

    /// 0...1 for the level meters (same scale as dictation's: -55 dB → 0, -5 dB → 1).
    public static func meter(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-9))
        return min(max((db + 55) / 50, 0), 1)
    }

    /// A chunk too quiet to hold speech worth decoding (about -54 dBFS RMS): Whisper only invents text there.
    public static func isNearSilent(_ s: [Float], threshold: Float = 0.002) -> Bool { rms(s) < threshold }

    /// The same, measured only where the VAD heard speech (`ranges` relative to `s`): a chunk can hold
    /// up to 3 s of merged silence, which would make a quiet short sentence look silent.
    public static func isNearSilent(_ s: [Float], speech ranges: [Range<Int>], threshold: Float = 0.002) -> Bool {
        let inside = ranges.flatMap { r -> ArraySlice<Float> in
            let c = r.clamped(to: 0..<s.count)
            return s[c]
        }
        return isNearSilent(inside.isEmpty ? s : Array(inside), threshold: threshold)
    }
}

/// Notices a channel that delivers only digital silence (exact zeros). That is what a process tap
/// gives when System Audio Recording is denied (there is no API to ask beforehand), and also when
/// nothing plays at all, so the UI wording must allow for both. Any real sound clears it.
public struct SilenceWatch: Sendable {
    public enum State: String, Equatable, Sendable { case waiting, sound, silent }
    public let afterSamples: Int
    public private(set) var state: State = .waiting
    private var zeros = 0

    public init(afterSeconds: Double = 8) { afterSamples = Int(afterSeconds * Double(sampleRate)) }

    /// `peak` of a buffer of `count` samples (at 16 kHz). Returns the new state when it changes.
    public mutating func feed(peak: Float, count: Int) -> State? {
        let next: State
        if peak > 1e-6 {
            zeros = 0
            next = .sound
        } else {
            zeros += count
            next = state == .sound || zeros < afterSamples ? state : .silent
        }
        guard next != state else { return nil }
        state = next
        return next
    }
}

/// Audio from a Core Audio device as interleaved Float32 buffers -> mono.
public enum Downmix {
    /// Average of every channel of an interleaved buffer.
    public static func average(_ interleaved: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels > 1 else { return Array(interleaved) }
        let frames = interleaved.count / channels
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[f * channels + c] }
            out[f] = sum * scale
        }
        return out
    }

    /// The first channel of an interleaved buffer (a mic's channel 1, like dictation hears it).
    public static func first(_ interleaved: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels > 1 else { return Array(interleaved) }
        return stride(from: 0, to: interleaved.count - channels + 1, by: channels).map { interleaved[$0] }
    }

    /// Which of an aggregate device's input buffers hold the tap: the last ones, `wanted` channels in
    /// all. The aggregate clocks off the output device, and if that device also has inputs (a
    /// headset), their buffers come first. nil if the buffers don't add up.
    public static func tailBuffers(channelCounts: [Int], wanted: Int) -> Range<Int>? {
        var channels = 0
        var i = channelCounts.count
        while i > 0, channels < wanted {
            i -= 1
            channels += channelCounts[i]
        }
        return channels == wanted && i < channelCounts.count ? i..<channelCounts.count : nil
    }
}

/// The maximum meeting length: a warning shortly before, then stop and save.
public struct MeetingLimit: Sendable {
    public static let choices = [30, 60, 120, 180]
    public static let defaultMinutes = 120
    public static let warnSeconds = 5 * 60

    public enum Action: Equatable, Sendable { case warn(minutesLeft: Int), stop }

    public let maxSeconds: Int
    private var warned = false

    public init(minutes: Int) { maxSeconds = max(1, minutes) * 60 }

    /// Call every second or so with the time recorded.
    public mutating func check(elapsed: Int) -> Action? {
        if elapsed >= maxSeconds { return .stop }
        let left = maxSeconds - elapsed
        if !warned, left <= Self.warnSeconds, maxSeconds > Self.warnSeconds {
            warned = true
            return .warn(minutesLeft: max(1, (left + 59) / 60))
        }
        return nil
    }

    /// A recording this short was probably started by mistake ("keep or discard?"). Not a long
    /// meeting where you only listened and the others' audio wasn't captured.
    public static func looksAccidental(words: Int, seconds: Double) -> Bool { words < 20 && seconds < 5 * 60 }

    public static func title(_ minutes: Int) -> String { minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" }
}

/// Free disk space while recording: two 16 kHz 16-bit channels need ~3.8 MB a minute, and the Mac
/// needs room of its own.
public enum DiskSpace {
    public static let bytesPerMinute = Int64(2 * sampleRate * WAV.bytesPerSample * 60)
    public static let reserve: Int64 = 500_000_000

    public enum Level: Equatable, Sendable { case ok, low(minutesLeft: Int), critical }

    public static func minutesLeft(freeBytes: Int64) -> Int { Int(max(0, freeBytes - reserve) / bytesPerMinute) }

    /// Warn under an hour of recording left; stop under two minutes.
    public static func level(freeBytes: Int64) -> Level {
        let m = minutesLeft(freeBytes: freeBytes)
        if m < 2 { return .critical }
        return m < 60 ? .low(minutesLeft: m) : .ok
    }
}

/// A first-in, first-out queue with O(1) pops (an Array's removeFirst is O(n)). `pushFront` puts a
/// job back at the head (a retry).
public struct Deque<Element> {
    private var items: [Element] = []
    private var head = 0

    public init() {}

    public var isEmpty: Bool { head >= items.count }
    public var count: Int { items.count - head }

    public mutating func append(_ e: Element) { items.append(e) }
    public mutating func append(contentsOf es: [Element]) { items.append(contentsOf: es) }

    public mutating func pushFront(_ e: Element) {
        if head > 0 { head -= 1; items[head] = e } else { items.insert(e, at: 0) }
    }

    public mutating func popFirst() -> Element? {
        guard head < items.count else { return nil }
        let e = items[head]
        head += 1
        if head > 64, head * 2 > items.count { items.removeFirst(head); head = 0 } // reclaim now and then
        return e
    }
}
