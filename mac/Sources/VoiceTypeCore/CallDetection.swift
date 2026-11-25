import Foundation

/// Apps whose use of the microphone means "you are on a call". Matched on the bundle id of the
/// process that has input running (browsers record from a helper process, so prefixes).
public enum CallApps {
    public struct App: Equatable, Sendable {
        public let name: String
        /// What a meeting started from this app is called.
        public let meetingTitle: String
        /// A browser: a call in a web page (Google Meet, Teams on the web…).
        public let isBrowser: Bool
    }

    static let known: [(prefix: String, app: App)] = [
        ("us.zoom.", App(name: "Zoom", meetingTitle: "Zoom call", isBrowser: false)),
        ("com.microsoft.teams", App(name: "Microsoft Teams", meetingTitle: "Teams call", isBrowser: false)),
        ("com.tinyspeck.slackmacgap", App(name: "Slack", meetingTitle: "Slack huddle", isBrowser: false)),
        ("com.apple.FaceTime", App(name: "FaceTime", meetingTitle: "FaceTime call", isBrowser: false)),
        ("com.cisco.webex", App(name: "Webex", meetingTitle: "Webex meeting", isBrowser: false)),
        ("Cisco-Systems.Spark", App(name: "Webex", meetingTitle: "Webex meeting", isBrowser: false)),
        ("com.hnc.Discord", App(name: "Discord", meetingTitle: "Discord call", isBrowser: false)),
        ("net.whatsapp.WhatsApp", App(name: "WhatsApp", meetingTitle: "WhatsApp call", isBrowser: false)),
        ("desktop.WhatsApp", App(name: "WhatsApp", meetingTitle: "WhatsApp call", isBrowser: false)),
        ("com.skype.skype", App(name: "Skype", meetingTitle: "Skype call", isBrowser: false)),
        ("com.google.Chrome", App(name: "Chrome", meetingTitle: "Browser call", isBrowser: true)),
        ("com.apple.Safari", App(name: "Safari", meetingTitle: "Browser call", isBrowser: true)),
        ("com.apple.WebKit", App(name: "Safari", meetingTitle: "Browser call", isBrowser: true)),
        ("company.thebrowser.", App(name: "Arc", meetingTitle: "Browser call", isBrowser: true)),
        ("com.microsoft.edgemac", App(name: "Edge", meetingTitle: "Browser call", isBrowser: true)),
        ("com.brave.Browser", App(name: "Brave", meetingTitle: "Browser call", isBrowser: true)),
        ("org.mozilla.firefox", App(name: "Firefox", meetingTitle: "Browser call", isBrowser: true)),
        ("com.vivaldi.Vivaldi", App(name: "Vivaldi", meetingTitle: "Browser call", isBrowser: true)),
        ("com.operasoftware.Opera", App(name: "Opera", meetingTitle: "Browser call", isBrowser: true)),
    ]

    public static func app(bundleID: String) -> App? {
        known.first { bundleID.hasPrefix($0.prefix) }?.app
    }
}

/// When a call starts and ends, from snapshots of which call apps are using the microphone. A call
/// "starts" once an app has held the mic for `startAfter` seconds (a voice message or a quick
/// dictation in Slack doesn't count) and "ends" once no call app has used it for `endAfter` seconds
/// (muting doesn't release the mic in most apps, and a short drop while switching devices isn't an end).
public struct CallWatch: Sendable {
    public enum Event: Equatable, Sendable { case started(CallApps.App), ended(CallApps.App) }

    public var startAfter: Double
    public var endAfter: Double
    private var since: [String: Double] = [:]
    private var lastSeen: Double?
    public private(set) var active: CallApps.App?

    public init(startAfter: Double = 6, endAfter: Double = 20) {
        self.startAfter = startAfter
        self.endAfter = endAfter
    }

    /// `apps`: call apps with input running now; `now`: seconds on any monotonic clock.
    public mutating func feed(_ apps: [CallApps.App], now: Double) -> Event? {
        let names = Set(apps.map(\.name))
        since = since.filter { names.contains($0.key) }
        for n in names where since[n] == nil { since[n] = now }
        if let call = active {
            if !apps.isEmpty { lastSeen = now; return nil }
            if now - (lastSeen ?? now) >= endAfter {
                active = nil
                lastSeen = nil
                return .ended(call)
            }
            return nil
        }
        // A native call app wins over a browser that also has the mic.
        let ready = apps.filter { now - (since[$0.name] ?? now) >= startAfter }
        guard let app = ready.first(where: { !$0.isBrowser }) ?? ready.first else { return nil }
        active = app
        lastSeen = now
        return .started(app)
    }
}
