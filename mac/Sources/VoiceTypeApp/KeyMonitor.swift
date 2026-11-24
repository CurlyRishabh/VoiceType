import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Which key starts dictation.
enum TriggerKey: String, CaseIterable {
    case fn
    case rightOption = "right_option"
    case optionSpace = "option_space"

    var title: String {
        switch self {
        case .fn: return "fn (globe)"
        case .rightOption: return "Right ⌥"
        case .optionSpace: return "⌥ Space"
        }
    }

    static var current: TriggerKey { TriggerKey(rawValue: UserDefaults.standard.string(forKey: Key.trigger) ?? "") ?? .fn }
}

/// Watches the trigger key system-wide and reports raw presses; `TriggerGesture` decides what they mean.
///
/// fn and right ⌥ are modifiers, which normal shortcuts can't use, so they are read with a
/// LISTEN-ONLY event tap: it sees key events but cannot block or change them, and it is allowed in
/// the App Sandbox once the user grants Input Monitoring. Only the trigger key, esc and the fact
/// that "some other key was pressed" are used; key contents are never recorded.
/// ⌥ Space keeps using Carbon's RegisterEventHotKey, which needs no permission; so do the
/// separate hands-free shortcut (⇧⌥ Space) and the meeting shortcut (⌃⌥ R).
///
/// The tap runs on its own thread and stamps each press when it happens. On the main thread a slow
/// moment (starting the microphone) could delay or drop the release of a quick tap, which turned a
/// double-tap into a short hold.
final class KeyMonitor {
    /// Main thread. `time`: when the key moved (system uptime), not when this runs.
    var onTrigger: ((_ down: Bool, _ time: TimeInterval) -> Void)?
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?
    var onHandsFreeKey: (() -> Void)?
    /// ⌃⌥ R: start or stop a meeting recording.
    var onMeetingKey: (() -> Void)?

    private(set) var trigger: TriggerKey = .fn
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false // tap thread (or main, for ⌥ Space)
    private let hotKey = HotKey(id: 1)
    private let handsFreeHotKey = HotKey(id: 2)
    private let meetingHotKey = HotKey(id: 3)
    private var lastHandsFreePress: TimeInterval = 0
    private var lastMeetingPress: TimeInterval = 0
    var pausedUntil: Date?

    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var tapRunning: Bool { tap != nil }

    static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }
    @discardableResult static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    init() {
        hotKey.onPress = { [weak self] in self?.report(true) }
        hotKey.onRelease = { [weak self] in self?.report(false) }
        handsFreeHotKey.onPress = { [weak self] in
            guard let self, !self.isPaused else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastHandsFreePress > 0.25 else { return } // ignore key repeat
            self.lastHandsFreePress = now
            self.onHandsFreeKey?()
        }
        // Works while "Pause" is on: that pauses the dictation key, not meetings.
        meetingHotKey.onPress = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastMeetingPress > 0.5 else { return } // key repeat, or a double press
            self.lastMeetingPress = now
            self.onMeetingKey?()
        }
    }

    /// ⌃⌥ R starts and stops a meeting recording (Settings → Meetings). Chosen to clash with neither
    /// VoiceType's dictation keys nor other dictation apps' usual meeting shortcuts.
    static var meetingShortcutOn: Bool { UserDefaults.standard.bool(forKey: Key.meetingShortcut) }
    static let meetingShortcutTitle = "⌃⌥R"

    /// ⇧⌥ Space starts and stops hands-free dictation (Settings → Dictation).
    static var handsFreeShortcutOn: Bool { UserDefaults.standard.bool(forKey: Key.handsFreeShortcut) }

    /// (Re)configures for the chosen key. Returns false if the event tap couldn't be created
    /// (Input Monitoring not granted yet); the caller retries when the app becomes active.
    @discardableResult
    func start(_ key: TriggerKey) -> Bool {
        trigger = key
        triggerDown = false
        if key == .optionSpace {
            hotKey.register(HotKey.Preset(title: "⌥ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)))
        } else {
            hotKey.unregister()
        }
        if Self.handsFreeShortcutOn {
            handsFreeHotKey.register(HotKey.Preset(title: "⇧⌥ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey)))
        } else {
            handsFreeHotKey.unregister()
        }
        if Self.meetingShortcutOn {
            meetingHotKey.register(HotKey.Preset(title: Self.meetingShortcutTitle, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey)))
        } else {
            meetingHotKey.unregister()
        }
        // The tap also provides esc and "other key" for every trigger, so create it whenever possible.
        if tap == nil { installTap() }
        return key == .optionSpace || tap != nil
    }

    private func installTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = src
        // Its own thread, so nothing the app does on the main thread can delay or drop a key event.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        thread.name = "VoiceType key listener"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged:
            switch trigger {
            case .fn where code == kVK_Function:
                report(event.flags.contains(.maskSecondaryFn))
            case .rightOption where code == kVK_RightOption:
                report(event.flags.contains(.maskAlternate))
            default:
                break
            }
        case .keyDown:
            if code == kVK_Escape {
                DispatchQueue.main.async { self.onEscape?() }
            } else if !(trigger == .optionSpace && code == kVK_Space) {
                DispatchQueue.main.async { self.onOtherKey?() }
            }
        default:
            break
        }
    }

    /// Called on the tap thread (fn, right ⌥) or the main thread (⌥ Space).
    private func report(_ down: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        guard down != triggerDown else { return } // ignore repeats
        triggerDown = down
        DispatchQueue.main.async {
            if self.isPaused { return }
            self.onTrigger?(down, time)
        }
    }
}

/// Carbon global hot key (works in the sandbox, no permission). Reports press and release.
/// Several can be registered: each reacts only to its own `id`.
final class HotKey {
    struct Preset { let title: String; let keyCode: UInt32; let modifiers: UInt32 }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(id: UInt32) {
        self.id = id
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            let me = Unmanaged<HotKey>.fromOpaque(user!).takeUnretainedValue()
            var hit = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hit)
            guard hit.id == me.id else { return OSStatus(eventNotHandledErr) } // another HotKey's
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { me.onPress?() } else { me.onRelease?() }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ preset: Preset) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5654_5950), id: self.id) // "VTYP"
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// macOS's "Press 🌐 key to" setting. Must be "Do Nothing", or every fn press also opens emoji etc.
enum FnKeySetting {
    /// nil when the sandbox doesn't let us read it.
    static var isDoNothing: Bool? {
        guard let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int else { return nil }
        return v == 0
    }

    static func openKeyboardSettings() {
        for u in ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension", "x-apple.systempreferences:com.apple.preference.keyboard"] {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }
}
