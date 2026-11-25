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
        guard isTrusted else { return (nil, nil) }
        let system = AXUIElementCreateSystemWide()
        // Asked on every dictation start: a busy app must not stall it (the default wait is 6 s).
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return (nil, nil) }
        let element = el as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return (nil, nil) } // never read passwords
        var value: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return (nil, nil) }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return (nil, nil) }
        let ns = text as NSString
        let start = max(0, min(range.location, ns.length))
        let end = max(start, min(range.location + range.length, ns.length))
        return (ns.substring(to: start), ns.substring(from: end))
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

    static func focusedField() -> Field? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let element = el as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int, n > maxWatchedCharacters { return nil }
        var rangeRef: CFTypeRef?
        guard let text = value(of: element), text.utf16.count <= maxWatchedCharacters,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }
        let ns = text as NSString
        let start = max(0, min(range.location, ns.length))
        let end = max(start, min(range.location + range.length, ns.length))
        return Field(element: element, before: ns.substring(to: start), after: ns.substring(from: end))
    }

    /// Whether `element` still has the keyboard focus.
    static func isFocused(_ element: AXUIElement) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return false }
        return CFEqual(el, element)
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
