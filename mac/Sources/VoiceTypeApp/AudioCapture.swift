import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import VoiceTypeCore

/// Small Core Audio property helpers.
enum AudioDevices {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func device(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        get(AudioObjectID(kAudioObjectSystemObject), selector, AudioObjectID(kAudioObjectUnknown)).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static var defaultInput: AudioObjectID? { device(kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutput: AudioObjectID? { device(kAudioHardwarePropertyDefaultOutputDevice) }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func sampleRate(_ device: AudioObjectID) -> Double? {
        get(device, kAudioDevicePropertyNominalSampleRate, Float64(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func isAlive(_ device: AudioObjectID) -> Bool { (get(device, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) ?? 0) != 0 }

    /// The formats of a device's input streams, in buffer-list order.
    static func inputFormats(_ device: AudioObjectID) -> [AudioStreamBasicDescription] {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return [] }
        return streams.compactMap { get($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) }
    }

    /// VoiceType's own process as a Core Audio object (nil before it has ever used audio).
    static var ownProcess: AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Calls `body` on `queue` whenever a property of `object` changes (removed again on deinit).
    final class Watch {
        private let object: AudioObjectID
        private var addr: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock

        init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             queue: DispatchQueue, _ body: @escaping () -> Void) {
            self.object = object
            addr = AudioDevices.address(selector, scope)
            self.queue = queue
            block = { _, _ in body() }
            AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        }

        deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block) }
    }
}

struct CaptureError: LocalizedError {
    let errorDescription: String?
    init(_ what: String, _ status: OSStatus) { errorDescription = "\(what) (Core Audio error \(status))" }
    init(_ what: String) { errorDescription = what }
}

/// When a channel last delivered audio, read by the meeting's no-audio watchdog on the main thread;
/// and which capture is current, so a replaced one's last buffers are dropped.
final class AudioClock: @unchecked Sendable {
    private let last = Atomic<UInt64>(0)
    private let current = Atomic<Int>(0)

    func mark() { last.store(AudioGetCurrentHostTime(), ordering: .relaxed) }

    var secondsSinceAudio: Double {
        let l = last.load(ordering: .relaxed), now = AudioGetCurrentHostTime()
        return l == 0 || now < l ? 0 : Double(AudioConvertHostTimeToNanos(now - l)) / 1e9
    }

    func makeCurrent(_ id: Int) { current.store(id, ordering: .relaxed) }
    func isCurrent(_ id: Int) -> Bool { current.load(ordering: .relaxed) == id }
}

/// 16 kHz mono audio from a capture. `first`: the first buffer after the capture (re)started, so the
/// meeting can line it up exactly.
struct CapturedAudio {
    let samples: [Float]
    let peak: Float
    let hostTime: UInt64
    let first: Bool
}

/// Reads one Core Audio device's input with an IOProc and hands out 16 kHz mono Float32, stamped
/// with the host time it was captured at (so the two meeting channels line up).
///
/// The IOProc runs on Core Audio's real-time IO thread and only copies the samples out; downmix and
/// sample-rate conversion happen on `work`, so a slow moment never makes the device drop a cycle
/// (which would also glitch dictation on the same mic). Several IOProcs on one device is a normal
/// Core Audio case (it is how several apps share a mic), so this runs alongside dictation's engine.
final class DeviceCapture {
    enum Channels {
        /// A microphone: its first channel, as dictation hears it.
        case first
        /// A tap inside an aggregate device: the average of the last `count` channels (see
        /// `Downmix.tailBuffers`); 0 = the last stream, whatever it holds.
        case tail(count: Int)
    }

    /// On `work`.
    var onAudio: ((CapturedAudio) -> Void)?
    /// The device's sample rate, stream layout or presence changed (on `control`).
    var onFormatChange: (() -> Void)?

    let device: AudioObjectID
    let id: Int
    private let channels: Channels
    private let clock: AudioClock
    private let work: DispatchQueue
    private let control: DispatchQueue
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var startedRate: Double?
    private var startedLayout: [UInt32] = []
    private var watches: [AudioDevices.Watch] = []
    private var firstPending = true // IO thread only, once started
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    init(device: AudioObjectID, channels: Channels, clock: AudioClock, label: String, control: DispatchQueue) {
        self.device = device
        self.channels = channels
        self.clock = clock
        id = Self.ids.add(1, ordering: .relaxed).newValue
        work = DispatchQueue(label: label, qos: .userInitiated)
        self.control = control
    }

    private static let ids = Atomic<Int>(0)

    /// The rate or stream layout differs from when it started (or the device is gone).
    var formatChanged: Bool {
        !AudioDevices.isAlive(device) || AudioDevices.sampleRate(device) != startedRate
            || AudioDevices.inputFormats(device).map(\.mChannelsPerFrame) != startedLayout
    }

    /// Call on `control`.
    func start() throws {
        let formats = AudioDevices.inputFormats(device)
        // The HAL hands IOProcs 32-bit float; check rather than assume.
        if let bad = formats.first(where: { $0.mFormatID != kAudioFormatLinearPCM || $0.mFormatFlags & kAudioFormatFlagIsFloat == 0 || $0.mBitsPerChannel != 32 }) {
            throw CaptureError("Unsupported audio format (\(bad.mBitsPerChannel)-bit, flags \(bad.mFormatFlags))")
        }
        startedLayout = formats.map(\.mChannelsPerFrame)
        let rate = AudioDevices.sampleRate(device) ?? formats.first.map(\.mSampleRate) ?? 48_000
        startedRate = AudioDevices.sampleRate(device)
        if rate != Double(sampleRate) {
            sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = sourceFormat.flatMap { AVAudioConverter(from: $0, to: target) }
        }
        let changed: () -> Void = { [weak self] in self?.onFormatChange?() }
        watches = [
            AudioDevices.Watch(device, kAudioDevicePropertyNominalSampleRate, queue: control, changed),
            AudioDevices.Watch(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput, queue: control, changed),
            AudioDevices.Watch(device, kAudioDevicePropertyDeviceIsAlive, queue: control, changed),
        ]

        var procID: AudioDeviceIOProcID?
        // No queue: the block runs on the IO thread itself and only copies.
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, input, inputTime, _, _ in
            self?.copyOut(input, inputTime)
        }
        guard status == noErr, let procID else { watches = []; throw CaptureError("Could not open the audio device", status) }
        self.procID = procID
        clock.mark() // the watchdog counts from now
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
            watches = []
            throw CaptureError("Could not start the audio device", status)
        }
    }

    func stop() {
        watches = []
        guard let id = procID else { return }
        AudioDeviceStop(device, id)
        AudioDeviceDestroyIOProcID(device, id)
        procID = nil
    }

    deinit { stop() }

    /// IO thread: pick the buffers, copy them, and leave.
    private func copyOut(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }
        let range: Range<Int>
        switch channels {
        case .first:
            range = 0..<1
        case .tail(let count) where count > 0:
            // Never fall back to "all buffers": that would mix a headset's mic into Others.
            range = Downmix.tailBuffers(channelCounts: list.map { Int($0.mNumberChannels) }, wanted: count) ?? (list.count - 1)..<list.count
        case .tail:
            range = (list.count - 1)..<list.count
        }
        var parts: [([Float], Int)] = []
        parts.reserveCapacity(range.count)
        for i in range {
            let b = list[i]
            guard let data = b.mData, b.mNumberChannels > 0 else { continue }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            parts.append((Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n)), Int(b.mNumberChannels)))
        }
        guard !parts.isEmpty else { return }
        let host = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : AudioGetCurrentHostTime()
        let first = firstPending
        firstPending = false
        clock.mark()
        work.async { [weak self] in self?.convert(parts, host, first) }
    }

    /// `work`: downmix, resample, hand on.
    private func convert(_ parts: [([Float], Int)], _ host: UInt64, _ first: Bool) {
        let mono: [Float]
        switch channels {
        case .first:
            mono = parts[0].0.withUnsafeBufferPointer { Downmix.first($0, channels: parts[0].1) }
        case .tail:
            mono = Self.weightedAverage(parts.map { p in (p.0.withUnsafeBufferPointer { Downmix.average($0, channels: p.1) }, p.1) })
        }
        guard !mono.isEmpty else { return }
        let out = resample(mono)
        if !out.isEmpty || first { onAudio?(CapturedAudio(samples: out, peak: AudioLevel.peak(mono), hostTime: host, first: first)) }
    }

    /// Mono parts weighted by how many channels each came from.
    private static func weightedAverage(_ parts: [([Float], Int)]) -> [Float] {
        guard let first = parts.first?.0, parts.count > 1 else { return parts.first?.0 ?? [] }
        let total = Float(parts.reduce(0) { $0 + $1.1 })
        var out = [Float](repeating: 0, count: first.count)
        for (samples, weight) in parts where samples.count == out.count {
            let w = Float(weight) / total
            for i in out.indices { out[i] += samples[i] * w }
        }
        return out
    }

    /// Same streaming conversion as dictation's Recorder: one converter for the whole recording, fed
    /// one buffer at a time, so no samples are lost at buffer edges.
    private func resample(_ mono: [Float]) -> [Float] {
        guard let converter, let sourceFormat else { return mono }
        guard let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return [] }
        src.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * target.sampleRate / sourceFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

/// Keeps one capture of a meeting channel going: opens it, switches it when the device or its
/// format changes (the new capture starts before the old one stops, so a failed switch costs
/// nothing), and retries with a backoff when opening fails. Everything runs on `control`; `start`
/// and `stop` never block the caller.
class ChannelCapture {
    var onAudio: ((CapturedAudio) -> Void)?
    /// Opening failed and is being retried (once per failure, until it works again). Main thread.
    var onTrouble: ((String) -> Void)?
    /// Switched to a new capture: the device's name, and whether it follows trouble. Main thread.
    var onSwitched: ((_ device: String, _ afterTrouble: Bool) -> Void)?

    let clock = AudioClock()
    let control: DispatchQueue
    private var running = false
    private var attempt = 0
    private var retry: DispatchWorkItem?
    private var troubled = false
    private var lastOpen: TimeInterval = 0
    private var recheck: DispatchWorkItem?
    /// Device notifications come in bursts (and opening a device causes some): at most one
    /// unforced switch every this many seconds, the rest re-checked afterwards.
    static let settle: TimeInterval = 2

    init(label: String) { control = DispatchQueue(label: label) }

    /// `done` (main thread) gets nil once audio is flowing, or why it couldn't start.
    func start(_ done: @escaping (Error?) -> Void) {
        control.async {
            self.running = true
            do {
                try self.open()
                self.lastOpen = ProcessInfo.processInfo.systemUptime
                self.didStart()
                DispatchQueue.main.async { done(nil) }
            } catch {
                self.running = false
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    func stop() {
        control.async {
            self.running = false
            self.retry?.cancel()
            self.retry = nil
            self.recheck?.cancel()
            self.recheck = nil
            self.close()
        }
    }

    /// The watchdog saw no audio for a while: open again, even on the same device.
    func nudge() { control.async { self.reopen(force: true) } }

    // Subclass hooks (on `control`).
    func open() throws { fatalError("override") }
    func close() {}
    func didStart() {}
    /// True when the current capture still matches the system's device and format.
    var isCurrent: Bool { true }
    var deviceName: String { "" }

    /// A device or format notification (`force` false), or a retry / watchdog nudge (true).
    func reopen(force: Bool) {
        guard running, force || !isCurrent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastOpen < Self.settle {
            guard recheck == nil else { return }
            let item = DispatchWorkItem { [weak self] in self?.recheck = nil; self?.reopen(force: false) }
            recheck = item
            control.asyncAfter(deadline: .now() + Self.settle, execute: item)
            return
        }
        do {
            try open()
            lastOpen = ProcessInfo.processInfo.systemUptime
            attempt = 0
            retry?.cancel()
            retry = nil
            let wasTroubled = troubled
            troubled = false
            // A watchdog nudge that worked says nothing here: the watchdog sees the audio come back.
            if !force || wasTroubled {
                let name = deviceName
                DispatchQueue.main.async { self.onSwitched?(name, wasTroubled) }
            }
        } catch {
            NSLog("VoiceType meeting: %@ reopen failed: %@", control.label, error.localizedDescription)
            attempt += 1
            if !troubled {
                troubled = true
                let why = error.localizedDescription
                DispatchQueue.main.async { self.onTrouble?(why) }
            }
            let item = DispatchWorkItem { [weak self] in self?.reopen(force: true) }
            retry?.cancel()
            retry = item
            control.asyncAfter(deadline: .now() + min(8, pow(2, Double(attempt - 1))), execute: item)
        }
    }

    /// Forwards only the current capture's audio (a replaced one may still have buffers in flight).
    func forward(_ c: DeviceCapture) {
        let id = c.id, clock = self.clock
        c.onAudio = { [weak self] audio in if clock.isCurrent(id) { self?.onAudio?(audio) } }
        c.onFormatChange = { [weak self] in self?.reopen(force: false) }
    }
}

/// The meeting's microphone: the default input device, followed when it changes (AirPods connect,
/// a headset is unplugged). Separate from dictation's recorder, which keeps working meanwhile.
final class MicCapture: ChannelCapture {
    private var capture: DeviceCapture?
    private var watch: AudioDevices.Watch?

    init() { super.init(label: "meeting-mic-control") }

    override func open() throws {
        guard let device = AudioDevices.defaultInput else { throw CaptureError("No microphone available.") }
        let c = DeviceCapture(device: device, channels: .first, clock: clock, label: "meeting-mic", control: control)
        forward(c)
        clock.makeCurrent(c.id)
        do { try c.start() } catch { clock.makeCurrent(capture?.id ?? 0); throw error }
        capture?.stop() // only now: a failed switch keeps the old one running
        capture = c
    }

    override func didStart() {
        watch = AudioDevices.Watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, queue: control) { [weak self] in
            self?.reopen(force: false)
        }
    }

    override func close() {
        watch = nil
        capture?.stop()
        capture = nil
    }

    override var isCurrent: Bool {
        guard let c = capture else { return false }
        return c.device == AudioDevices.defaultInput && !c.formatChanged
    }

    override var deviceName: String { capture.flatMap { AudioDevices.name($0.device) } ?? "the microphone" }
}

/// The sound of every other app (the people on the call): a Core Audio process tap on all output
/// except VoiceType's own, read through a private aggregate device (macOS 14.4+). macOS asks for
/// "System Audio Recording" the first time. If that is denied the tap simply delivers silence: there
/// is no error and no public API to check first, so the meeting watches for silence instead.
final class SystemAudioCapture: ChannelCapture {
    private struct Tap {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var capture: DeviceCapture?
        var outputUID: String?
        /// The output device's rate when this was built (AirPods switching profile change it).
        var outputRate: Double?
        var outputRateWatch: AudioDevices.Watch?

        mutating func close() {
            outputRateWatch = nil
            capture?.stop()
            capture = nil
            if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            aggregate = AudioObjectID(kAudioObjectUnknown)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private var current = Tap()
    private var watch: AudioDevices.Watch?

    init() { super.init(label: "meeting-system-audio-control") }

    override func open() throws {
        let output = AudioDevices.defaultOutput
        let outputUID = output.flatMap(AudioDevices.uid)
        var next: Tap
        do {
            next = try build(clockedBy: outputUID)
        } catch where outputUID != nil {
            // A Multi-Output or aggregate default output may refuse to be nested: tap on its own.
            NSLog("VoiceType meeting: tap with %@ failed (%@), trying without a clock device", outputUID ?? "-", error.localizedDescription)
            next = try build(clockedBy: nil)
        }
        if let output {
            next.outputRate = AudioDevices.sampleRate(output)
            next.outputRateWatch = AudioDevices.Watch(output, kAudioDevicePropertyNominalSampleRate, queue: control) { [weak self] in self?.reopen(force: false) }
        }
        current.close() // only now: a failed rebuild keeps the old tap running
        current = next
    }

    private func build(clockedBy outputUID: String?) throws -> Tap {
        var t = Tap()
        t.outputUID = outputUID
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioDevices.ownProcess.map { [$0] } ?? [])
        description.name = "VoiceType meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &t.tap)
        guard status == noErr else { throw CaptureError("Could not create the system audio tap", status) }

        var config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceType meeting audio",
            kAudioAggregateDeviceUIDKey: "dev.offline.voicetype.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Not "auto start": that makes AudioDeviceStart wait until some app plays audio (forever,
            // when nothing plays or the permission is off). Started now, the tap delivers silence
            // until there is sound, which is also how a missing permission is noticed.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if let outputUID {
            config[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            config[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &t.aggregate)
        guard status == noErr else {
            t.aggregate = AudioObjectID(kAudioObjectUnknown)
            t.close()
            throw CaptureError("Could not create the meeting audio device", status)
        }
        // The tap's channels: its own format, else whatever its stream (the last one) holds.
        let channels = AudioDevices.get(t.tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()).map { Int($0.mChannelsPerFrame) } ?? 0
        let c = DeviceCapture(device: t.aggregate, channels: .tail(count: channels), clock: clock, label: "meeting-system-audio", control: control)
        forward(c)
        let previous = current.capture?.id ?? 0
        clock.makeCurrent(c.id)
        do { try c.start() } catch {
            clock.makeCurrent(previous)
            t.close()
            throw error
        }
        t.capture = c
        return t
    }

    override func didStart() {
        // The aggregate clocks off the output device; when that changes (AirPods connect), rebuild.
        watch = AudioDevices.Watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, queue: control) { [weak self] in
            self?.reopen(force: false)
        }
    }

    override func close() {
        watch = nil
        current.close()
    }

    /// Same output device (by UID) and an unchanged format: nothing to rebuild.
    override var isCurrent: Bool {
        guard let c = current.capture else { return false }
        let uid = AudioDevices.defaultOutput.flatMap(AudioDevices.uid)
        let sameOutput = current.outputUID == nil || current.outputUID == uid
        // Clocked by the output device: rebuild when its rate changed since (AirPods switching to the
        // headset profile do that).
        let rateSame = current.outputUID == nil || AudioDevices.defaultOutput.flatMap(AudioDevices.sampleRate) == current.outputRate
        return sameOutput && rateSame && !c.formatChanged
    }

    override var deviceName: String { "other apps’ sound" }
}
