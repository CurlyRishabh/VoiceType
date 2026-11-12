import AppKit
import Carbon.HIToolbox

/// Global hot key via Carbon RegisterEventHotKey: works in the App Sandbox and needs no
/// Input Monitoring permission. Reports both press and release so hold-to-talk works.
final class HotKey {
    struct Preset { let title: String; let keyCode: UInt32; let modifiers: UInt32 }

    static let presets: [Preset] = [
        Preset(title: "⌥ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        Preset(title: "⌃ ⌥ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        Preset(title: "⌃ ⌥ D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)),
    ]

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
        if let ref { UnregisterEventHotKey(ref) }
        let id = EventHotKeyID(signature: OSType(0x5654_5950), id: 1) // "VTYP"
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

/// Floating "pill" near the bottom of the screen: live level bars while listening, status otherwise.
/// Non-activating, so the app you're typing in keeps focus.
final class HUD {
    private let panel: NSPanel
    private let bars = LevelBars()
    private let label = NSTextField(labelWithString: "")
    private var hideItem: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 22
        bg.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        bars.frame = NSRect(x: 16, y: 10, width: 228, height: 24)
        label.frame = NSRect(x: 12, y: 13, width: 236, height: 18)
        bg.addSubview(bars)
        bg.addSubview(label)
        panel.contentView = bg
    }

    func listening() {
        hideItem?.cancel()
        bars.reset()
        bars.isHidden = false
        label.isHidden = true
        show()
    }

    func level(_ v: Float) { bars.push(v) }

    func status(_ text: String, autoHide: TimeInterval? = nil) {
        hideItem?.cancel()
        bars.isHidden = true
        label.isHidden = false
        label.stringValue = text
        show()
        if let autoHide {
            let item = DispatchWorkItem { [weak self] in self?.hide() }
            hideItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: item)
        }
    }

    func hide() { panel.orderOut(nil) }

    private func show() {
        guard UserDefaults.standard.bool(forKey: Key.showHUD) else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 48))
        }
        panel.orderFrontRegardless()
    }
}

final class LevelBars: NSView {
    private var values = [Float](repeating: 0, count: 28)
    func reset() { values = values.map { _ in 0 }; needsDisplay = true }
    func push(_ v: Float) { values.removeFirst(); values.append(v); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(values.count)
        let w = bounds.width / (n * 1.6)
        let gap = w * 0.6
        NSColor.systemRed.setFill()
        for (i, v) in values.enumerated() {
            let h = max(w, CGFloat(v) * bounds.height)
            let x = CGFloat(i) * (w + gap) + gap / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
