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
/// ⌥ Space keeps using Carbon's RegisterEventHotKey, which needs no permission.
final class KeyMonitor {
    var onTrigger: ((_ down: Bool) -> Void)?
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var trigger: TriggerKey = .fn
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private let hotKey = HotKey()
    var pausedUntil: Date?

    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var tapRunning: Bool { tap != nil }

    static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }
    @discardableResult static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    init() {
        hotKey.onPress = { [weak self] in self?.report(true) }
        hotKey.onRelease = { [weak self] in self?.report(false) }
    }

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
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
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

    private func report(_ down: Bool) {
        guard down != triggerDown else { return } // ignore repeats
        triggerDown = down
        if isPaused { return }
        DispatchQueue.main.async { self.onTrigger?(down) }
    }
}

/// Carbon global hot key (works in the sandbox, no permission). Reports press and release.
final class HotKey {
    struct Preset { let title: String; let keyCode: UInt32; let modifiers: UInt32 }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            let me = Unmanaged<HotKey>.fromOpaque(user!).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { me.onPress?() } else { me.onRelease?() }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ preset: Preset) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5654_5950), id: 1) // "VTYP"
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
