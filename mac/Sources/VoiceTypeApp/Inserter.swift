import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceTypeCore

/// Types dictated text into the frontmost app: puts it on the pasteboard (marked transient and
/// concealed so clipboard managers ignore it), sends ⌘V, then restores the previous clipboard.
/// Posting ⌘V needs the Accessibility permission; without it the text is left on the clipboard.
enum Inserter {
    enum Outcome { case pasted, copiedOnly }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Text around the cursor of the focused field, if the app exposes it via Accessibility.
    static func focusedContext() -> (before: String?, after: String?) {
        guard let f = focusedField(limit: .max) else { return (nil, nil) }
        return (f.before, f.after)
    }

    /// The focused text field and the text around the cursor, just before a paste (nil for
    /// password fields, fields that don't expose their text, or without Accessibility).
    struct Field {
        let element: AXUIElement
        let before: String
        let after: String
    }

    /// Fields longer than this (a terminal, a long document) aren't watched: reading them every
    /// few seconds would cost more than it is worth.
    static let maxWatchedCharacters = 20_000

    /// Asked on every dictation, on the main thread: each Accessibility call waits at most 0.25 s for
    /// a busy app (the default is 6 s). Password fields are never read.
    static func focusedField(limit: Int = maxWatchedCharacters) -> Field? {
        guard isTrusted else { return miss("no Accessibility") }
        guard let element = focusedElement() else { return miss("no focused element (AX \(lastFocusError.rawValue))") }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return miss("password field") }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int, n > limit { return miss("too long") }
        var valueRef: CFTypeRef?
        let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard let text = valueRef as? String else { return miss("no text value (AX \(valueError.rawValue))") }
        guard text.utf16.count <= limit else { return miss("too long") }
        var rangeRef: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return miss("no cursor (AX \(rangeError.rawValue))") }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return miss("no cursor") }
        let ns = text as NSString
        let start = max(0, min(range.location, ns.length))
        let end = max(start, min(range.location + range.length, ns.length))
        return Field(element: element, before: ns.substring(to: start), after: ns.substring(from: end))
    }

    /// Why the last `focusedField()` found nothing (for diagnostics.log; never the text).
    private(set) static var lastMiss = ""
    private static func miss(_ why: String) -> Field? {
        lastMiss = why
        return nil
    }

    /// The element with the keyboard focus in the app in front. The system-wide focus query fails
    /// (kAXErrorCannotComplete) on macOS 27 even for TextEdit, and Chromium/Electron apps never
    /// answered it, so the app itself is asked; Electron builds its accessibility tree only once asked to
    /// (AXManualAccessibility), so a first miss turns that on and asks again.
    static func focusedElement() -> AXUIElement? {
        if let pid = frontmostPID() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            if let e = focused(in: app) { return e }
            lastFocusError = focusError
            // Once per app: a busy app that just didn't answer shouldn't hold up every paste.
            if manualAccessibilityAsked.insert(pid).inserted,
               AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                usleep(150_000) // the tree is built asynchronously
                if let e = focused(in: app) { return e }
            }
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        return focused(in: system)
    }

    private static var manualAccessibilityAsked = Set<pid_t>() // main thread

    /// The app in front, from Accessibility (that query still works system-wide), else from NSWorkspace.
    static func frontmostPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var app: CFTypeRef?
        var pid: pid_t = 0
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
           let a = app, CFGetTypeID(a) == AXUIElementGetTypeID(), AXUIElementGetPid(a as! AXUIElement, &pid) == .success {
            return pid
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static var focusError: AXError = .success
    private(set) static var lastFocusError: AXError = .success

    private static func focused(in container: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        focusError = AXUIElementCopyAttributeValue(container, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusError == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    enum Focus { case here, moved(AXUIElement), elsewhere, unknown }

    /// Whether `element` still has the keyboard focus, asked of its own app (see `focusedElement`):
    /// `.moved` to the element that has it in the same app, `.elsewhere` when another app is in front.
    /// `.unknown` when the app doesn't answer in time: a busy app isn't a move to another field.
    static func focus(of element: AXUIElement) -> Focus {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, let front = frontmostPID() else { return .unknown }
        // Each app keeps its own focused element, so another app in front is checked first.
        guard front == pid else { return .elsewhere }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let el = focused(in: app) else { return .unknown }
        return CFEqual(el, element) ? .here : .moved(el)
    }

    /// A field's whole text (nil if it can't be read any more).
    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func insert(_ text: String) -> Outcome {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org conventions: clipboard managers skip transient/concealed items.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let trusted = isTrusted
        Diagnostics.log("insert: \(text.count) chars, accessibility \(trusted ? "on" : "OFF"), \(trusted ? "pasting with ⌘V" : "copied only")")
        guard trusted else { return .copiedOnly }

        let ourChange = pb.changeCount
        sendCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Only restore if nothing else changed the clipboard in the meantime.
            guard pb.changeCount == ourChange else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return .pasted
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { old in
            let copy = NSPasteboardItem()
            for type in old.types { if let data = old.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// A small log of what happened to dictations and permissions, for troubleshooting without asking
/// the user to repeat things: ~/Library/Application Support/VoiceType/diagnostics.log (no text
/// content, only lengths and states; the newest 200 lines are kept).
enum Diagnostics {
    private static let queue = DispatchQueue(label: "diagnostics", qos: .utility)
    static var file: URL {
        ModelStore.realHome.appendingPathComponent("Library/Application Support/VoiceType/diagnostics.log")
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let bundle = Bundle.main.bundleURL.path
        queue.async {
            var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append("\(stamp) \(line) [\(bundle)]")
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
