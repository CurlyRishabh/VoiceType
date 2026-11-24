import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
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

    /// VoiceType's own process as a Core Audio object (nil before it has ever played a sound).
    static var ownProcess: AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Calls `body` on `queue` whenever the system's default input or output device changes.
    final class DefaultDeviceWatch {
        private var addr: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock

        init(_ selector: AudioObjectPropertySelector, queue: DispatchQueue, _ body: @escaping () -> Void) {
            addr = AudioDevices.address(selector)
            self.queue = queue
            block = { _, _ in body() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }

        deinit { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) }
    }
}

struct CaptureError: LocalizedError {
    let errorDescription: String?
    init(_ what: String, _ status: OSStatus) { errorDescription = "\(what) (Core Audio error \(status))" }
}

/// Reads one Core Audio device's input with an IOProc and hands out 16 kHz mono Float32, stamped
/// with the host time it was captured at (so the two meeting channels line up). The HAL delivers
/// its canonical format to IOProcs: 32-bit float, interleaved within each buffer.
///
/// Several IOProcs on one device is a normal Core Audio case (it's how several apps share a mic), so
/// this runs alongside dictation's AVAudioEngine.
final class DeviceCapture {
    enum Channels {
        /// A microphone: its first channel, as dictation hears it.
        case first
        /// A tap inside an aggregate device: the average of the last `count` channels (see `Downmix.tailBuffers`).
        case tail(count: Int)
    }

    /// 16 kHz mono samples, the peak of the raw buffer, and the host time of its first frame. On the
    /// capture's own audio queue.
    var onAudio: ((_ samples: [Float], _ peak: Float, _ hostTime: UInt64) -> Void)?

    let device: AudioObjectID
    private let channels: Channels
    /// The IOProc runs here. Start and stop must be called from elsewhere: `AudioDeviceStop` waits for
    /// the IO cycle in progress, which may be waiting for this queue.
    private let queue: DispatchQueue
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    init(device: AudioObjectID, channels: Channels, label: String) {
        self.device = device
        self.channels = channels
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    func start() throws {
        let rate = AudioDevices.sampleRate(device) ?? 48_000
        if rate != Double(sampleRate) {
            sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = sourceFormat.flatMap { AVAudioConverter(from: $0, to: target) }
        }
        var id: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&id, device, queue) { [weak self] _, input, inputTime, _, _ in
            self?.process(input, inputTime)
        }
        guard status == noErr, let id else { throw CaptureError("Could not open the audio device", status) }
        procID = id
        status = AudioDeviceStart(device, id)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            procID = nil
            throw CaptureError("Could not start the audio device", status)
        }
    }

    func stop() {
        guard let id = procID else { return }
        AudioDeviceStop(device, id)
        AudioDeviceDestroyIOProcID(device, id)
        procID = nil
    }

    deinit { stop() }

    private func process(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }
        let mono: [Float]
        switch channels {
        case .first:
            mono = Self.samples(list[0]) { Downmix.first($0, channels: $1) }
        case .tail(let count):
            let range = Downmix.tailBuffers(channelCounts: list.map { Int($0.mNumberChannels) }, wanted: count) ?? 0..<list.count
            let parts = range.map { i in (Self.samples(list[i]) { Downmix.average($0, channels: $1) }, Int(list[i].mNumberChannels)) }
            mono = Self.weightedAverage(parts)
        }
        guard !mono.isEmpty else { return }
        let peak = AudioLevel.peak(mono)
        let host = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : AudioGetCurrentHostTime()
        let out = resample(mono)
        if !out.isEmpty { onAudio?(out, peak, host) }
    }

    private static func samples(_ buffer: AudioBuffer, _ mix: (UnsafeBufferPointer<Float>, Int) -> [Float]) -> [Float] {
        guard let data = buffer.mData, buffer.mNumberChannels > 0 else { return [] }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        return mix(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), Int(buffer.mNumberChannels))
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

/// The meeting's microphone: the default input device, followed when it changes (AirPods connect,
/// a headset is unplugged). Separate from dictation's recorder, which keeps working meanwhile.
final class MicCapture {
    var onAudio: ((_ samples: [Float], _ peak: Float, _ hostTime: UInt64) -> Void)?
    /// The new device's name, after a switch.
    var onSwitch: ((String) -> Void)?

    /// Opens, switches and closes the device (the audio itself arrives on the capture's own queue).
    private let queue = DispatchQueue(label: "meeting-mic-control")
    private var capture: DeviceCapture?
    private var watch: AudioDevices.DefaultDeviceWatch?

    func start() throws {
        try queue.sync { try open() }
        watch = AudioDevices.DefaultDeviceWatch(kAudioHardwarePropertyDefaultInputDevice, queue: queue) { [weak self] in
            guard let self, self.capture != nil, AudioDevices.defaultInput != self.capture?.device else { return }
            do {
                try self.open()
                if let d = self.capture?.device, let name = AudioDevices.name(d) { self.onSwitch?(name) }
            } catch {
                NSLog("VoiceType meeting: mic switch failed: %@", error.localizedDescription)
            }
        }
    }

    func stop() {
        watch = nil
        queue.sync {
            capture?.stop()
            capture = nil
        }
    }

    private func open() throws {
        capture?.stop()
        capture = nil
        guard let device = AudioDevices.defaultInput else { throw EngineError("No microphone available.") }
        let c = DeviceCapture(device: device, channels: .first, label: "meeting-mic")
        c.onAudio = { [weak self] in self?.onAudio?($0, $1, $2) }
        try c.start()
        capture = c
    }
}

/// The sound of every other app (the people on the call): a Core Audio process tap on all output
/// except VoiceType's own, read through a private aggregate device (macOS 14.4+). macOS asks for
/// "System Audio Recording" the first time. If that is denied the tap simply delivers silence: there
/// is no error and no public API to check first, so the meeting watches for silence instead.
final class SystemAudioCapture {
    var onAudio: ((_ samples: [Float], _ peak: Float, _ hostTime: UInt64) -> Void)?

    /// Opens, rebuilds and closes the tap (the audio itself arrives on the capture's own queue).
    private let queue = DispatchQueue(label: "meeting-system-audio-control")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var capture: DeviceCapture?
    private var watch: AudioDevices.DefaultDeviceWatch?

    func start() throws {
        try queue.sync { try open() }
        // The aggregate clocks off the output device; when that changes (AirPods connect), rebuild.
        watch = AudioDevices.DefaultDeviceWatch(kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in
            guard let self, self.capture != nil else { return }
            do { try self.open() } catch { NSLog("VoiceType meeting: system audio restart failed: %@", error.localizedDescription) }
        }
    }

    func stop() {
        watch = nil
        queue.sync { close() }
    }

    deinit { if capture != nil || tap != kAudioObjectUnknown { close() } }

    private func open() throws {
        close()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioDevices.ownProcess.map { [$0] } ?? [])
        description.name = "VoiceType meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { tap = AudioObjectID(kAudioObjectUnknown); throw CaptureError("Could not create the system audio tap", status) }

        var config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceType meeting audio",
            kAudioAggregateDeviceUIDKey: "dev.offline.voicetype.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if let output = AudioDevices.defaultOutput, let uid = AudioDevices.uid(output) {
            config[kAudioAggregateDeviceMainSubDeviceKey] = uid
            config[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        guard status == noErr else { aggregate = AudioObjectID(kAudioObjectUnknown); close(); throw CaptureError("Could not create the meeting audio device", status) }

        let channels = AudioDevices.get(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()).map { Int($0.mChannelsPerFrame) } ?? 2
        let c = DeviceCapture(device: aggregate, channels: .tail(count: max(1, channels)), label: "meeting-system-audio")
        c.onAudio = { [weak self] in self?.onAudio?($0, $1, $2) }
        do { try c.start() } catch { close(); throw error }
        capture = c
    }

    private func close() {
        capture?.stop()
        capture = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}
