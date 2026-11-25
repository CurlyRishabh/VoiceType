import CoreAudio
import Foundation
import VoiceTypeCore

/// Notices when a call starts or ends in another app: every 2 s it asks Core Audio which processes
/// have their microphone input running (no permission needed, nothing is recorded) and keeps the
/// call apps among them (Zoom, Teams, Slack, FaceTime, browsers for Meet…). VoiceType itself is
/// left out, so its own recording doesn't count as a call.
final class CallDetector {
    var onEvent: ((CallWatch.Event) -> Void)?

    private let queue = DispatchQueue(label: "call-detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var watch = CallWatch()

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { self.watch = CallWatch() }
    }

    /// The call in progress, if one was seen (main thread reads a copy).
    private(set) var activeCall: CallApps.App?

    private func poll() {
        let apps = Self.appsUsingMic()
        let event = watch.feed(apps, now: ProcessInfo.processInfo.systemUptime)
        let active = watch.active
        DispatchQueue.main.async {
            self.activeCall = active
            if let event { self.onEvent?(event) }
        }
    }

    /// Call apps with microphone input running right now, VoiceType excluded.
    static func appsUsingMic() -> [CallApps.App] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        let me = getpid()
        var out: [CallApps.App] = []
        for p in objects {
            guard (AudioDevices.get(p, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0,
                  AudioDevices.get(p, kAudioProcessPropertyPID, pid_t(0)) != me,
                  let bundle = AudioDevices.string(p, kAudioProcessPropertyBundleID),
                  let app = CallApps.app(bundleID: bundle), !out.contains(app) else { continue }
            out.append(app)
        }
        return out
    }
}
