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
        var lastError: String?
    }

    var onLevel: ((MeetingChannel, Float) -> Void)?
    var onSilence: ((MeetingChannel, SilenceWatch.State) -> Void)?
    var onWords: ((Int) -> Void)?

    let config: Config
    private let speech: SpeechHost
    private let pipes: [MeetingChannel: Pipe]
    private let jobs = DispatchQueue(label: "meeting-chunks", qos: .utility)

    // `jobs` queue only.
    private var pending: [Job] = []
    private var busy = false
    private var finishing = false
    private var whenDone: ((Outcome) -> Void)?
    private var segments: [TranscriptSegment] = []
    private var lastRaw: [MeetingChannel: String] = [:]
    private var lastClean: [MeetingChannel: String] = [:]
    private var decodeMillis = 0
    private var languages: [String] = []
    private var engine = ""
    private var chunks = 0
    private var failed = 0
    private var lastError: String?
    private var words = 0

    struct Job {
        let channel: MeetingChannel
        let plan: ChunkPlan
        let file: URL
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
        }
    }

    // MARK: feeding

    /// Live or headless audio for one channel (16 kHz mono). `peak`: of the raw buffer, for the silence watch.
    func append(_ channel: MeetingChannel, _ samples: [Float], peak: Float, hostTime: UInt64?) {
        pipes[channel]?.append(samples, peak: peak, hostTime: hostTime)
    }

    /// Recovery: runs the VAD over the WAVs already in the folder.
    func ingestRecordedAudio() {
        for pipe in pipes.values { pipe.ingestFile() }
    }

    /// Samples recorded so far on the longer channel.
    var recordedSamples: Int { pipes.values.map(\.recorded).max() ?? 0 }

    /// Stop feeding first. Flushes the VAD tails, decodes what is left, and calls back once (on an
    /// internal queue) with every segment.
    func finish(_ completion: @escaping (Outcome) -> Void) {
        let group = DispatchGroup()
        for pipe in pipes.values { group.enter(); pipe.finish { group.leave() } }
        group.notify(queue: jobs) {
            self.finishing = true
            self.whenDone = completion
            self.checkDone()
        }
    }

    /// Closes the WAVs without transcribing (the app is quitting; the next launch recovers the meeting).
    func closeFiles() {
        for pipe in pipes.values { pipe.closeNow() }
    }

    // MARK: decoding, one chunk at a time

    private func enqueue(_ new: [Job]) {
        jobs.async {
            self.pending += new
            self.pump()
        }
    }

    private func pump() {
        guard !busy else { return }
        var next: (Job, [Float])?
        while next == nil, !pending.isEmpty {
            let job = pending.removeFirst()
            let samples = WavReader.read(job.file, job.plan.range)
            // Near-silent: nothing worth decoding, only room for Whisper to invent text.
            if !samples.isEmpty, !AudioLevel.isNearSilent(samples) { next = (job, samples) }
        }
        guard var (job, samples) = next else { checkDone(); return }
        if config.tokenBudget, WhisperBudget.needsPadding(whisper: config.spec.kind == .hindiEnglish, language: config.spec.language) {
            samples = WhisperBudget.pad(samples)
        }
        busy = true
        chunks += 1
        speech.transcribeTimed(config.spec, samples: samples, prompt: config.prompt) { [weak self] result in
            guard let self else { return }
            self.jobs.async {
                self.busy = false
                switch result {
                case .success(let r): self.add(r, job)
                case .failure(let e):
                    self.failed += 1
                    self.lastError = e.localizedDescription
                    NSLog("VoiceType meeting: chunk failed: %@", e.localizedDescription)
                }
                self.pump()
            }
        }
    }

    private func add(_ r: SpeechHost.TimedChunk, _ job: Job) {
        decodeMillis += r.decodeMillis
        engine = r.engine
        let offset = Double(job.plan.range.lowerBound) / Double(sampleRate)
        let length = Double(job.plan.range.count) / Double(sampleRate)
        let kept = MeetingTextFilter.clean(r.segments, speechMillis: job.plan.speechSamples * 1000 / sampleRate, previous: lastRaw[job.channel])
        guard !kept.isEmpty else { return }
        lastRaw[job.channel] = kept.map(\.text).joined(separator: " ")
        if !r.language.isEmpty, !languages.contains(r.language) { languages.append(r.language) }
        for t in kept {
            let text = config.cleanup.clean(t.text, previous: lastClean[job.channel])
            guard !text.isEmpty else { continue }
            lastClean[job.channel] = text
            segments.append(TranscriptSegment(start: offset + min(max(0, t.start), length), end: offset + min(max(t.start, t.end), length),
                                              channel: job.channel, text: text, language: r.language))
            words += MeetingTranscript.wordCount(text)
        }
        let w = words
        onWords?(w)
    }

    private func checkDone() {
        guard finishing, !busy, pending.isEmpty, let done = whenDone else { return }
        whenDone = nil
        let speechSeconds = pipes.mapValues { Double($0.speechSamples) / Double(sampleRate) }
        done(Outcome(segments: segments.sorted { $0.start < $1.start }, durationSeconds: Double(recordedSamples) / Double(sampleRate),
                     speechSeconds: speechSeconds, decodeMillis: decodeMillis, languages: languages, engine: engine,
                     chunks: chunks, failedChunks: failed, lastError: lastError))
    }

    // MARK: the files

    /// Echo de-dup, then transcript.md / transcript.json / meeting.json; audio deleted unless kept.
    /// Returns the finished info.
    @discardableResult
    static func write(_ outcome: Outcome, info base: MeetingInfo, folder: URL, echoFilter: Bool, keepAudio: Bool,
                      stoppedAt: Date?) -> MeetingInfo {
        var info = base
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
        let allFailed = outcome.chunks > 0 && outcome.failedChunks == outcome.chunks
        info.status = allFailed ? .failed : .ready
        info.error = allFailed ? (outcome.lastError ?? "Speech recognition failed.") : nil
        do {
            try MeetingFiles.writeTranscript(segments, info: info, to: folder)
        } catch {
            info.status = .failed
            info.error = "Could not write the transcript: \(error.localizedDescription)"
        }
        // Audio goes only once the transcript is safely written (a failed meeting keeps it for a retry).
        info.audioKept = keepAudio || info.status != .ready
        if !info.audioKept { MeetingFiles.deleteAudio(folder) }
        try? MeetingFiles.writeInfo(info, to: folder)
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
    private var writeFailed = false
    private(set) var speechSamples = 0

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

    func append(_ samples: [Float], peak: Float, hostTime: UInt64?) {
        queue.async {
            if let start = self.startHostTime, let host = hostTime {
                let expected = host > start ? ChannelAligner.position(nanosSinceStart: AudioConvertHostTimeToNanos(host - start)) : 0
                let gap = self.aligner.gap(written: self.position, expected: expected)
                if gap > 0 { self.take([Float](repeating: 0, count: gap), write: true) }
            }
            if let state = self.silence.feed(peak: peak, count: samples.count) { self.onSilence?(self.channel, state) }
            self.take(samples, write: true)
            self.meter(samples)
        }
    }

    /// Recovery: the WAV is already there; run it through the VAD a second at a time.
    func ingestFile() {
        queue.async {
            WavReader.repairHeader(self.file)
            let total = WavReader.sampleCount(self.file)
            var at = 0
            while at < total {
                let block = WavReader.read(self.file, at..<min(total, at + sampleRate))
                if block.isEmpty { break }
                self.take(block, write: false)
                at += block.count
            }
        }
    }

    private func take(_ samples: [Float], write: Bool) {
        if write, let writer, !writeFailed {
            do { try writer.append(samples) } catch {
                writeFailed = true // disk full: the guard stops the meeting; keep transcribing what is there
                NSLog("VoiceType meeting: writing %@ failed: %@", channel.fileName, error.localizedDescription)
            }
        }
        position += samples.count
        vad.accept(samples)
        var jobs: [ChunkPlan] = []
        for seg in vad.drain() {
            speechSamples += seg.length
            jobs += chunker.add(seg)
        }
        if !vad.isSpeech { jobs += chunker.flush(position: position) }
        send(jobs)
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
            self.vad.flush()
            var jobs: [ChunkPlan] = []
            for seg in self.vad.drain() {
                self.speechSamples += seg.length
                jobs += self.chunker.add(seg)
            }
            jobs += self.chunker.finish(total: self.position)
            self.writer?.close()
            self.send(jobs)
            done()
        }
    }

    func closeNow() { queue.sync { writer?.close() } }
}
