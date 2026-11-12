import AVFoundation
import Foundation
import VoiceTypeCore

/// Captures the default input with AVAudioEngine, converts to 16 kHz mono Float32, runs Silero VAD
/// and auto-stops after trailing silence. Audio is kept in memory only.
final class Recorder {
    enum StopReason { case user, silence, noSpeech, maxDuration, error }

    struct Captured {
        let samples: [Float]
        let segments: [Segment]?
        let speechDetected: Bool
        let reason: StopReason
        var durationMillis: Int { samples.count * 1000 / sampleRate }
        var speechMillis: Int { segments.map { $0.reduce(0) { $0 + $1.length } * 1000 / sampleRate } ?? durationMillis }
    }

    var onLevel: ((Float) -> Void)?
    var onAutoStop: ((StopReason) -> Void)?

    /// Can be switched off mid-recording (tap became a hold).
    var autoStop = true
    var silenceMillis = 1500
    let noSpeechTimeoutMillis = 8000
    let maxDurationMillis = 5 * 60_000

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "recorder", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    private var vad: SherpaVAD?
    private var samples: [Float] = []
    private var segments: [Segment] = []
    private var speechSeen = false
    private var silentSamples = 0
    private var stopped = false
    private var reason: StopReason = .user
    private var frames = 0

    init(vadModel: URL?) {
        vad = vadModel.flatMap(SherpaVAD.init(model:))
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineError("No microphone available.") }
        converter = AVAudioConverter(from: format, to: target)
        samples.reserveCapacity(sampleRate * 30)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.convertAndProcess(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the audio (blocks briefly to drain the queue).
    func stop() -> Captured {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return queue.sync {
            stopped = true
            if let vad {
                vad.flush()
                let rest = vad.drain()
                if !rest.isEmpty { speechSeen = true }
                segments += rest
            }
            let c = Captured(samples: samples, segments: vad == nil ? nil : segments,
                             speechDetected: speechSeen || vad == nil, reason: reason)
            samples = []
            return c
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { stopped = true; samples = [] }
    }

    private func convertAndProcess(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        queue.async { self.process(chunk) }
    }

    private func process(_ chunk: [Float]) {
        if stopped { return }
        samples.append(contentsOf: chunk)

        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = sqrt(sum / Float(max(chunk.count, 1)))
        frames += 1
        if frames % 2 == 0, let onLevel {
            let db = 20 * log10(max(rms, 1e-9))
            let level = min(max((db + 55) / 50, 0), 1)
            DispatchQueue.main.async { onLevel(level) }
        }

        if let vad {
            vad.accept(chunk)
            let speech = vad.isSpeech
            if speech { speechSeen = true; silentSamples = 0 } else if speechSeen { silentSamples += chunk.count }
            segments += vad.drain()
            if autoStop {
                let silentMs = silentSamples * 1000 / sampleRate + Int(SherpaVAD.minSilence * 1000)
                if speechSeen && !speech && silentMs >= silenceMillis { finish(.silence); return }
                if !speechSeen && samples.count * 1000 / sampleRate >= noSpeechTimeoutMillis { finish(.noSpeech); return }
            }
        }
        if samples.count * 1000 / sampleRate >= maxDurationMillis { finish(.maxDuration) }
    }

    private func finish(_ r: StopReason) {
        reason = r
        stopped = true
        let cb = onAutoStop
        DispatchQueue.main.async { cb?(r) }
    }
}
