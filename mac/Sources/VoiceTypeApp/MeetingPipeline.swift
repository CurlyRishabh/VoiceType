import CoreAudio
import Foundation
import VoiceTypeCore

/// Everything between captured audio and the transcript, for one meeting:
///
/// * per channel (Me = mic, Others = system audio), on its own queue: alignment to the meeting
///   clock, the WAV on disk, Silero VAD and live chunking;
/// * one shared queue of chunks, decoded ONE at a time through SpeechHost (a dictation waits for at
///   most one chunk), each read back from the WAV, filtered and cleaned;
/// * at the end, echo de-dup, merging and the files.
///
/// Used live (fed by the captures), headless (`--meeting`) and to recover a meeting the app didn't
/// finish (fed from the WAVs already on disk). Callbacks come on internal queues.
final class MeetingPipeline {
    struct Config {
        var folder: URL
        var spec: EngineSpec
        var prompt: String?
        var cleanup: MeetingCleanup
        var vadModel: URL
        /// sherpa-onnx Whisper's 6-tokens-per-second workaround (8 s padded chunks); not for whisper.cpp.
        var tokenBudget = false
    }

    /// What the meeting produced, before echo de-dup.
    struct Outcome {
        var segments: [TranscriptSegment]
        var durationSeconds: Double
        var speechSeconds: [MeetingChannel: Double]
        var decodeMillis: Int
        var languages: [String]
        var engine: String
        var chunks: Int
        var failedChunks: Int
        /// Speech in the chunks that failed.
        var missingSeconds: Double
        var lastError: String?
    }

    var onLevel: ((MeetingChannel, Float) -> Void)?
    var onSilence: ((MeetingChannel, SilenceWatch.State) -> Void)?
    var onWords: ((Int) -> Void)?
    /// Segments just transcribed (live view), cleaned but before echo de-dup.
    var onSegments: (([TranscriptSegment]) -> Void)?
    /// Audio could not be written (disk full?): the meeting must stop. Once.
    var onWriteFailure: ((MeetingChannel, String) -> Void)?

    let config: Config
    private let speech: SpeechHost
    private let pipes: [MeetingChannel: Pipe]
    private let jobs = DispatchQueue(label: "meeting-chunks", qos: .utility)

    // `jobs` queue only.
    private var pending = Deque<Job>()
    private var readers: [MeetingChannel: WavReader] = [:]
    private var busy = false
    private var finishing = false
    private var whenDone: ((Outcome) -> Void)?
    private var segments: [TranscriptSegment] = []
    private var previous: [MeetingChannel: MeetingTextFilter.Previous] = [:]
    private var lastClean: [MeetingChannel: String] = [:]
    private var decodeMillis = 0
    private var languages: [String] = []
    private var engine = ""
    private var chunks = 0
    private var failed = 0
    private var missingSeconds = 0.0
    private var lastError: String?
    private var words = 0

    struct Job {
        let channel: MeetingChannel
        let plan: ChunkPlan
        let file: URL
        var attempt = 0

        var start: Double { Double(plan.range.lowerBound) / Double(sampleRate) }
        var end: Double { Double(plan.range.upperBound) / Double(sampleRate) }
    }

    /// `startHostTime`: the meeting clock for aligning live channels (nil = sequential, no alignment).
    /// `writeAudio`: false to read audio that is already on disk (recovery).
    init(config: Config, speech: SpeechHost, startHostTime: UInt64?, writeAudio: Bool = true) throws {
        self.config = config
        self.speech = speech
        var pipes: [MeetingChannel: Pipe] = [:]
        for ch in MeetingChannel.allCases {
            let url = config.folder.appendingPathComponent(ch.fileName)
            guard let vad = SherpaVAD(model: config.vadModel) else { throw EngineError("Could not load the voice detector.") }
            pipes[ch] = Pipe(channel: ch, file: url, writer: writeAudio ? try WavWriter(url: url) : nil, vad: vad,
                             maxChunk: config.tokenBudget ? WhisperBudget.maxChunkSamples : AudioChunker.maxChunk,
                             startHostTime: startHostTime)
        }
        self.pipes = pipes
        for pipe in pipes.values {
            pipe.onChunks = { [weak self] in self?.enqueue($0) }
            pipe.onLevel = { [weak self] in self?.onLevel?($0, $1) }
            pipe.onSilence = { [weak self] in self?.onSilence?($0, $1) }
            pipe.onWriteFailure = { [weak self] in self?.onWriteFailure?($0, $1) }
        }
    }

    // MARK: feeding

    /// Live or headless audio for one channel (16 kHz mono). `peak`: of the raw buffer, for the
    /// silence watch. `first`: the first buffer after a capture (re)started (aligned exactly).
    func append(_ channel: MeetingChannel, _ samples: [Float], peak: Float, hostTime: UInt64?, first: Bool = false) {
        pipes[channel]?.append(samples, peak: peak, hostTime: hostTime, first: first)
    }

    /// Recovery: runs the VAD over the WAVs already in the folder.
    func ingestRecordedAudio() {
        for pipe in pipes.values { pipe.ingestFile() }
    }

    /// Samples recorded so far on the longer channel.
    var recordedSamples: Int { pipes.values.map(\.recorded).max() ?? 0 }

    /// Seals the channels (audio arriving later is ignored), flushes the VAD tails, decodes what is
    /// left, and calls back once (on an internal queue) with every segment.
    func finish(_ completion: @escaping (Outcome) -> Void) {
        let group = DispatchGroup()
        for pipe in pipes.values { group.enter(); pipe.finish { group.leave() } }
        group.notify(queue: jobs) {
            self.finishing = true
            self.whenDone = completion
            self.checkDone()
        }
    }

    // MARK: decoding, one chunk at a time

    private func enqueue(_ new: [Job]) {
        jobs.async {
            self.pending.append(contentsOf: new)
            self.pump()
        }
    }

    private func reader(_ job: Job) -> WavReader? {
        if let r = readers[job.channel] { return r }
        let r = WavReader(url: job.file)
        readers[job.channel] = r
        return r
    }

    private func pump() {
        guard !busy else { return }
        var next: (Job, [Float])?
        while next == nil, let job = pending.popFirst() {
            let samples = reader(job)?.read(job.plan.range) ?? []
            // Near-silent where the VAD heard speech: only room for Whisper to invent text.
            if !samples.isEmpty, !AudioLevel.isNearSilent(samples, speech: job.plan.speechInChunk) {
                next = (job, samples)
            } else {
                previous[job.channel] = .init(text: "", end: job.end) // still separates the chunks around it
            }
        }
        guard let (job, audio) = next else { checkDone(); return }
        var samples = audio
        if config.tokenBudget, WhisperBudget.needsPadding(whisper: config.spec.kind == .hindiEnglish, language: config.spec.language) {
            samples = WhisperBudget.pad(samples)
        }
        busy = true
        if job.attempt == 0 { chunks += 1 }
        speech.transcribeTimed(config.spec, samples: samples, prompt: config.prompt) { [weak self] result in
            guard let self else { return }
            self.jobs.async {
                self.busy = false
                switch result {
                case .success(let r): self.add(r, job)
                case .failure(let e): self.failedChunk(job, e)
                }
                self.pump()
            }
        }
    }

    /// One retry (a model reload after a memory-pressure release can fail once); then the chunk is
    /// counted as missing, and the meeting keeps its audio.
    private func failedChunk(_ job: Job, _ e: Error) {
        NSLog("VoiceType meeting: chunk at %.1fs (%@) failed, attempt %d: %@", job.start, job.channel.rawValue, job.attempt + 1, e.localizedDescription)
        if job.attempt == 0 {
            var again = job
            again.attempt = 1
            pending.pushFront(again)
            return
        }
        failed += 1
        missingSeconds += Double(job.plan.speechSamples) / Double(sampleRate)
        lastError = e.localizedDescription
        previous[job.channel] = .init(text: "", end: job.end)
    }

    private func add(_ r: SpeechHost.TimedChunk, _ job: Job) {
        decodeMillis += r.decodeMillis
        engine = r.engine
        let length = job.end - job.start
        let (kept, next) = MeetingTextFilter.clean(r.segments, speechMillis: job.plan.speechSamples * 1000 / sampleRate,
                                                   previous: previous[job.channel], start: job.start, end: job.end)
        previous[job.channel] = next
        guard !kept.isEmpty else { return }
        if !r.language.isEmpty, !languages.contains(r.language) { languages.append(r.language) }
        let before = segments.count
        for t in kept {
            let text = config.cleanup.clean(t.text, previous: lastClean[job.channel])
            guard !text.isEmpty else { continue }
            lastClean[job.channel] = text
            segments.append(TranscriptSegment(start: job.start + min(max(0, t.start), length), end: job.start + min(max(t.start, t.end), length),
                                              channel: job.channel, text: text, language: r.language))
            words += MeetingTranscript.wordCount(text)
        }
        let w = words
        onWords?(w)
        if segments.count > before { onSegments?(Array(segments[before...])) }
    }

    private func checkDone() {
        guard finishing, !busy, pending.isEmpty, let done = whenDone else { return }
        whenDone = nil
        let speechSeconds = pipes.mapValues { Double($0.speechSamples) / Double(sampleRate) }
        done(Outcome(segments: segments.sorted { $0.start < $1.start }, durationSeconds: Double(recordedSamples) / Double(sampleRate),
                     speechSeconds: speechSeconds, decodeMillis: decodeMillis, languages: languages, engine: engine,
                     chunks: chunks, failedChunks: failed, missingSeconds: missingSeconds, lastError: lastError))
    }

    // MARK: the files

    /// Echo de-dup, then transcript.md / transcript.json, then meeting.json, and only then (if all
    /// of that is on disk and every chunk worked) the audio is deleted, unless it is kept. A crash at
    /// any point leaves either the audio or a finished transcript. Returns the finished info.
    @discardableResult
    static func write(_ outcome: Outcome, info base: MeetingInfo, folder: URL, echoFilter: Bool, keepAudio: Bool,
                      stoppedAt: Date?) -> MeetingInfo {
        var info = base
        if let onDisk = MeetingFiles.readInfo(folder) { info.title = onDisk.title } // renamed while wrapping up
        let (segments, removed) = echoFilter ? EchoFilter.apply(outcome.segments) : (outcome.segments, 0)
        info.durationSeconds = outcome.durationSeconds
        info.endedAt = info.endedAt ?? info.startedAt.addingTimeInterval(outcome.durationSeconds)
        info.decodeSeconds = Double(outcome.decodeMillis) / 1000
        info.rtf = outcome.durationSeconds > 0 ? info.decodeSeconds / outcome.durationSeconds : nil
        info.tailSeconds = stoppedAt.map { Date().timeIntervalSince($0) }
        if !outcome.engine.isEmpty { info.model = outcome.engine }
        info.languages = outcome.languages.sorted()
        info.wordCount = MeetingTranscript.wordCount(segments)
        info.echoLinesRemoved = removed
        info.failedChunks = outcome.failedChunks
        info.missingSeconds = outcome.missingSeconds
        info.status = .after(chunks: outcome.chunks, failed: outcome.failedChunks)
        switch info.status {
        case .failed: info.error = outcome.lastError ?? "Speech recognition failed."
        case .partial: info.error = "\(outcome.failedChunks) of \(outcome.chunks) parts couldn’t be transcribed: \(outcome.lastError ?? "unknown error")"
        default: info.error = nil
        }
        do {
            try MeetingFiles.writeTranscript(segments, info: info, to: folder)
        } catch {
            info.status = .failed
            info.error = "Could not write the transcript: \(error.localizedDescription)"
        }
        // Audio goes only once a complete transcript is safely written: a partial or failed meeting keeps it.
        info.audioKept = info.status.keepsAudio(setting: keepAudio)
        do {
            try MeetingFiles.writeInfo(info, to: folder)
        } catch {
            info.audioKept = true // meeting.json still says "transcribing": recovery needs the audio
        }
        if !info.audioKept { MeetingFiles.deleteAudio(folder) }
        NSLog("VoiceType meeting: %.0fs, %d chunks (%d failed), decode %.1fs, RTF %.3f, tail %.1fs, %d words, %d echo lines removed",
              info.durationSeconds, outcome.chunks, outcome.failedChunks, info.decodeSeconds, info.rtf ?? 0, info.tailSeconds ?? 0,
              info.wordCount, removed)
        PerfLog.shared.add(.init(date: Date(), engine: "meeting · " + (outcome.engine.isEmpty ? "–" : outcome.engine),
                                 audioMillis: Int(outcome.durationSeconds * 1000), decodeMillis: outcome.decodeMillis, loadMillis: 0))
        return info
    }
}

/// One channel: aligned audio -> WAV -> VAD -> chunks. Everything on its own serial queue.
private final class Pipe {
    let channel: MeetingChannel
    let file: URL
    var onChunks: (([MeetingPipeline.Job]) -> Void)?
    var onLevel: ((MeetingChannel, Float) -> Void)?
    var onSilence: ((MeetingChannel, SilenceWatch.State) -> Void)?
    var onWriteFailure: ((MeetingChannel, String) -> Void)?

    private let queue: DispatchQueue
    private let writer: WavWriter?
    private let vad: SherpaVAD
    private var chunker: LiveChunker
    private let aligner = ChannelAligner()
    private let startHostTime: UInt64?
    private var silence = SilenceWatch()
    private var position = 0
    private var levelSamples = 0
    private var levelPeak: Float = 0
    /// Finished, or the disk refused audio: nothing more goes in.
    private var sealed = false
    private(set) var speechSamples = 0
    private static let zeros = [Float](repeating: 0, count: sampleRate)

    init(channel: MeetingChannel, file: URL, writer: WavWriter?, vad: SherpaVAD, maxChunk: Int, startHostTime: UInt64?) {
        self.channel = channel
        self.file = file
        self.writer = writer
        self.vad = vad
        chunker = LiveChunker(maxChunk: maxChunk)
        self.startHostTime = startHostTime
        queue = DispatchQueue(label: "meeting-\(channel.rawValue)", qos: .userInitiated)
    }

    var recorded: Int { queue.sync { position } }

    func append(_ samples: [Float], peak: Float, hostTime: UInt64?, first: Bool) {
        queue.async {
            guard !self.sealed else { return }
            if let start = self.startHostTime, let host = hostTime {
                let expected = host > start ? ChannelAligner.position(nanosSinceStart: AudioConvertHostTimeToNanos(host - start)) : 0
                let gap = self.aligner.gap(written: self.position, expected: expected, exact: first)
                if gap > 0 { self.padSilence(gap) }
            }
            guard !samples.isEmpty, !self.sealed else { return }
            if let state = self.silence.feed(peak: peak, count: samples.count) { self.onSilence?(self.channel, state) }
            if self.write(samples) { self.analyze(samples) }
            self.meter(samples)
        }
    }

    /// Recovery: the WAV is already there; run it through the VAD a second at a time.
    func ingestFile() {
        queue.async {
            WavReader.repairHeader(self.file)
            guard let reader = WavReader(url: self.file) else { return }
            let total = reader.sampleCount
            var at = 0
            while at < total {
                let block = reader.read(at..<min(total, at + sampleRate))
                if block.isEmpty { break }
                self.analyze(block)
                at += block.count
            }
        }
    }

    /// A gap on the meeting clock (late start, device switch): silence on disk and for the VAD.
    private func padSilence(_ count: Int) {
        if let writer {
            do { try writer.appendSilence(count) } catch { failed(error); return }
        }
        var left = count
        while left > 0 {
            let n = min(left, Self.zeros.count)
            analyze(n == Self.zeros.count ? Self.zeros : Array(Self.zeros.prefix(n)))
            left -= n
        }
    }

    /// False (and the meeting is told to stop) when the disk refuses the audio.
    private func write(_ samples: [Float]) -> Bool {
        guard let writer else { return true }
        do { try writer.append(samples); return true } catch { failed(error); return false }
    }

    private func failed(_ error: Error) {
        guard !sealed else { return }
        sealed = true // later chunks would point at audio that isn't on disk
        NSLog("VoiceType meeting: writing %@ failed: %@", channel.fileName, error.localizedDescription)
        onWriteFailure?(channel, error.localizedDescription)
    }

    private func analyze(_ samples: [Float]) {
        position += samples.count
        vad.accept(samples)
        var plans: [ChunkPlan] = []
        for seg in vad.drain() {
            speechSamples += seg.length
            plans += chunker.add(seg)
        }
        if !vad.isSpeech { plans += chunker.flush(position: position) }
        send(plans)
    }

    private func send(_ plans: [ChunkPlan]) {
        guard !plans.isEmpty else { return }
        onChunks?(plans.map { MeetingPipeline.Job(channel: channel, plan: $0, file: file) })
    }

    /// About 20 level updates a second (the loudest buffer in each twentieth).
    private func meter(_ samples: [Float]) {
        levelSamples += samples.count
        levelPeak = max(levelPeak, AudioLevel.rms(samples))
        guard levelSamples >= sampleRate / 20 else { return }
        onLevel?(channel, AudioLevel.meter(levelPeak))
        levelSamples = 0
        levelPeak = 0
    }

    func finish(_ done: @escaping () -> Void) {
        queue.async {
            self.sealed = true
            self.vad.flush()
            var plans: [ChunkPlan] = []
            for seg in self.vad.drain() {
                self.speechSamples += seg.length
                plans += self.chunker.add(seg)
            }
            plans += self.chunker.finish(total: self.position)
            self.writer?.close()
            self.send(plans)
            done()
        }
    }
}
