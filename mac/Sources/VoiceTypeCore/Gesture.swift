import Foundation

/// Turns raw presses of the trigger key (fn, right ⌥ or ⌥ Space) into dictation actions:
///
/// * hold (≥ 0.3 s) → push-to-talk; release types the text
/// * double-tap (second press within 0.35 s of the first release) → hands-free; one more press finishes
/// * a single short tap → nothing (the provisional recording is discarded)
/// * another key while the trigger is down (fn+arrow, fn+F5, ⌥+letter) → normal shortcut, discard
/// * esc → cancel
///
/// Recording starts on the very first key-down so the first word is never clipped; whether it is
/// kept is decided later. Pure value type: time is passed in, so every path is unit tested.
public struct TriggerGesture: Sendable {
    public enum Event: Sendable, Equatable {
        case keyDown(TimeInterval)
        case keyUp(TimeInterval)
        case otherKey
        case escape
        case tick(TimeInterval)
        case stopButton
        case cancelButton
    }

    public enum Effect: Sendable, Equatable {
        /// Start recording now (provisionally).
        case begin
        /// It's a hold: show push-to-talk.
        case becameHold
        /// Double-tap: keep recording through pauses until the next press.
        case becameHandsFree
        /// Stop and type what was said.
        case finish
        /// Stop and throw the audio away.
        case cancel
    }

    public enum State: Sendable, Equatable {
        case idle
        case pressed(since: TimeInterval)
        case holding
        case awaitingSecondTap(releasedAt: TimeInterval)
        case handsFree
    }

    public var holdThreshold: TimeInterval = 0.30
    public var doubleTapWindow: TimeInterval = 0.35
    public private(set) var state: State = .idle

    public init() {}

    public var isActive: Bool { state != .idle }

    /// When the caller must send `.tick(now)` so a pending decision can be made.
    public var nextDeadline: TimeInterval? {
        switch state {
        case .pressed(let since): return since + holdThreshold
        case .awaitingSecondTap(let releasedAt): return releasedAt + doubleTapWindow
        default: return nil
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {

        // ---- idle
        case (.idle, .keyDown(let t)):
            state = .pressed(since: t)
            return [.begin]
        case (.idle, _):
            return []

        // ---- trigger is down, not yet decided
        case (.pressed(let since), .keyUp(let t)):
            if t - since >= holdThreshold { state = .idle; return [.finish] }
            state = .awaitingSecondTap(releasedAt: t)
            return []
        case (.pressed(let since), .tick(let t)):
            if t - since >= holdThreshold { state = .holding; return [.becameHold] }
            return []
        case (.pressed, .otherKey), (.pressed, .escape), (.pressed, .cancelButton):
            state = .idle
            return [.cancel]
        case (.pressed, .stopButton):
            state = .idle
            return [.finish]
        case (.pressed, _):
            return [] // key repeat

        // ---- push-to-talk
        case (.holding, .keyUp), (.holding, .stopButton):
            state = .idle
            return [.finish]
        case (.holding, .otherKey), (.holding, .escape), (.holding, .cancelButton):
            state = .idle
            return [.cancel]
        case (.holding, _):
            return []

        // ---- released quickly: waiting to see whether a second tap comes
        case (.awaitingSecondTap(let releasedAt), .keyDown(let t)):
            if t - releasedAt <= doubleTapWindow { state = .handsFree; return [.becameHandsFree] }
            state = .pressed(since: t)
            return [.cancel, .begin]
        case (.awaitingSecondTap(let releasedAt), .tick(let t)):
            if t - releasedAt > doubleTapWindow { state = .idle; return [.cancel] }
            return []
        case (.awaitingSecondTap, .otherKey), (.awaitingSecondTap, .escape), (.awaitingSecondTap, .cancelButton):
            state = .idle
            return [.cancel]
        case (.awaitingSecondTap, .stopButton):
            state = .idle
            return [.finish]
        case (.awaitingSecondTap, _):
            return []

        // ---- hands-free: typing other keys is allowed; the next trigger press finishes
        case (.handsFree, .keyDown), (.handsFree, .stopButton):
            state = .idle
            return [.finish]
        case (.handsFree, .escape), (.handsFree, .cancelButton):
            state = .idle
            return [.cancel]
        case (.handsFree, _):
            return []
        }
    }

    /// Starts hands-free directly (menu item / flow bar click).
    public mutating func startHandsFree() -> [Effect] {
        guard state == .idle else { return [] }
        state = .handsFree
        return [.begin, .becameHandsFree]
    }

    /// The recording ended on its own (error, time limit): forget any gesture in progress.
    public mutating func reset() { state = .idle }
}
