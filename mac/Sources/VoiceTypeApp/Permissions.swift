import AppKit
import AVFoundation
import VoiceTypeCore

/// Asks for macOS permissions so that the user only has to flip a switch.
///
/// macOS adds VoiceType to its Privacy & Security list the first time VoiceType asks, and shows its
/// own dialog then (with an "Open System Settings" button). So the first press of an Allow button
/// only asks. Later presses ask again (which re-adds VoiceType if it was removed from the list) and
/// open the right pane, where VoiceType is already listed and just needs switching on.
enum Permissions {
    enum Kind: String {
        case microphone, accessibility, inputMonitoring

        fileprivate var pane: String {
            switch self {
            case .microphone: return "Privacy_Microphone"
            case .accessibility: return "Privacy_Accessibility"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }

        fileprivate var askedKey: String { "asked_\(rawValue)" }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return Inserter.isTrusted
        case .inputMonitoring: return KeyMonitor.hasInputMonitoring
        }
    }

    /// True once VoiceType has asked, so it is already in the list in System Settings.
    static func hasAsked(_ kind: Kind) -> Bool {
        if kind == .microphone { return AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined }
        return UserDefaults.standard.bool(forKey: kind.askedKey)
    }

    static func buttonTitle(_ kind: Kind) -> String {
        hasAsked(kind) ? "Open System Settings" : "Allow…"
    }

    /// Asks macOS for the permission; `done` runs on the main thread once there is something new to show.
    static func request(_ kind: Kind, then done: @escaping () -> Void = {}) {
        guard !isGranted(kind) else { done(); return }
        let askedBefore = hasAsked(kind)
        switch kind {
        case .microphone:
            if !askedBefore {
                // The system dialog: Allow / Don't Allow. Nothing to switch on in Settings.
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: done) }
                return
            }
        case .accessibility:
            Inserter.requestTrust()
        case .inputMonitoring:
            KeyMonitor.requestInputMonitoring()
        }
        UserDefaults.standard.set(true, forKey: kind.askedKey)
        if askedBefore {
            // Give the request above a moment to (re)add VoiceType before Settings reads the list.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openPrivacy(kind.pane) }
        }
        done()
    }
}

/// "System Audio Recording", for the other side of a meeting. macOS has no public API to check it
/// or ask for it up front: it asks the first time a meeting starts its audio tap, and when it is
/// denied the tap just delivers silence. So the status is what the last meeting heard.
enum SystemAudioPermission {
    static var lastState: MeetingInfo.SystemAudio {
        MeetingInfo.SystemAudio(rawValue: UserDefaults.standard.string(forKey: Key.systemAudioState) ?? "") ?? .unknown
    }

    static var statusText: String {
        switch lastState {
        case .ok: return "Working in your last meeting"
        case .silent: return "Silent in your last meeting: switch VoiceType on in System Settings"
        case .unavailable: return "Couldn’t be captured in your last meeting"
        case .unknown: return "macOS asks the first time you record a meeting"
        }
    }

    /// Privacy & Security → Screen & System Audio Recording (VoiceType is under "System Audio Recording Only").
    static func openSettings() { openPrivacy("Privacy_ScreenCapture") }
}
