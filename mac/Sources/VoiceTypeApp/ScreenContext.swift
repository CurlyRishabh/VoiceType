import AppKit
import ApplicationServices
import VoiceTypeCore

/// The text on screen around a dictation, for `ScreenNames`: the front window's title and its
/// visible text (labels, messages, headings). Read-only through Accessibility, with a time and size
/// budget, off the main thread; kept in memory for that one dictation and never saved or logged.
enum ScreenContext {
    static func windowTexts(pid: pid_t, budget: TimeInterval = 0.12, maxElements: Int = 2000) -> (title: String?, texts: [String]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron apps (Slack…) build their tree only once asked; other apps ignore this.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let window = (attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute))
            .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        guard let window else { return (nil, []) }
        let title = attribute(window, kAXTitleAttribute) as? String
        let start = ProcessInfo.processInfo.systemUptime
        var queue = [window], next = 0, texts: [String] = [], chars = 0
        while next < queue.count, next < maxElements, chars < 60_000,
              ProcessInfo.processInfo.systemUptime - start < budget {
            let e = queue[next]
            next += 1
            let role = attribute(e, kAXRoleAttribute) as? String ?? ""
            // Only labels, headings and links: text fields (passwords among them) are never read here.
            if role == kAXStaticTextRole as String || role == "AXHeading" || role == "AXLink" {
                if let v = (attribute(e, kAXValueAttribute) as? String) ?? (attribute(e, kAXTitleAttribute) as? String), !v.isEmpty {
                    texts.append(v)
                    chars += v.count
                }
            }
            if let kids = attribute(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return (title, texts)
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}
