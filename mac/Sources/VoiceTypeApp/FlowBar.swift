import AppKit
import SwiftUI
import VoiceTypeCore

/// What the flow bar shows.
final class FlowModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, handsFree, typing, notice, meeting }

    /// A meeting recording, shown whenever no dictation needs the bar.
    struct Meeting: Equatable {
        var elapsed = 0
        var words = 0
        var title = "Meeting"
        var wrappingUp = false
        var micOnly = false
    }

    /// One bar of the meeting meter: how loud Me and Others were.
    struct MeetingLevel: Equatable {
        var me: Float = 0
        var others: Float = 0
    }

    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: 12)
    @Published var elapsed = 0
    @Published var notice = ""
    @Published var noticeAction: String?
    @Published var showIdle = true
    @Published var meeting: Meeting?
    @Published var meetingLevels = Array(repeating: MeetingLevel(), count: 14)
    @Published var meetingHover = false { didSet { if meetingHover != oldValue { onResize() } } }

    var onStop: () -> Void = {}
    var onMeetingStop: () -> Void = {}
    var onResize: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpen: () -> Void = {}
    /// Click on the meeting pill (not its Stop button): the live transcript.
    var onMeetingOpen: () -> Void = {}
    var onNoticeAction: () -> Void = {}

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    private var latestOthers: Float = 0
    private var meCount = 0

    /// Meeting levels come ~20 times a second per channel; the meter moves ~10 times a second, on the
    /// mic's beat (the mic always delivers audio; system audio only while something plays).
    func pushMeeting(_ channel: MeetingChannel, _ level: Float) {
        if channel == .others { latestOthers = level; return }
        meCount += 1
        guard meCount % 2 == 0 else { return }
        meetingLevels.removeFirst()
        meetingLevels.append(MeetingLevel(me: level, others: latestOthers))
        latestOthers *= 0.5 // fades if system audio stops arriving
    }
}

/// The pill pinned to the bottom of the screen. A non-activating panel that never becomes key, so
/// the app you're typing in keeps focus; the window is resized to the pill so it never blocks
/// clicks next to it.
final class FlowBar {
    let model = FlowModel()
    private let panel: FlowPanel
    private var noticeHide: DispatchWorkItem?

    init() {
        panel = FlowPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 16),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: FlowBarView(model: model))
        panel.contentView = host
        model.showIdle = UserDefaults.standard.bool(forKey: Key.flowBarIdle)
        model.onResize = { [weak self] in self?.layout() }
        layout()
    }

    /// `.idle` means "nothing for dictation": the meeting pill when a meeting is on.
    func set(_ requested: FlowModel.Phase) {
        let phase = requested == .idle && model.meeting != nil ? .meeting : requested
        if phase != .notice { noticeHide?.cancel() }
        if phase == .listening || phase == .handsFree, model.phase != .listening, model.phase != .handsFree {
            model.levels = model.levels.map { _ in 0 }
        }
        withAnimation(.easeOut(duration: 0.15)) { model.phase = phase }
        layout()
    }

    /// `then`: what to show when the notice goes away (decided at that moment).
    func notice(_ text: String, action: String? = nil, seconds: TimeInterval = 4, then: @escaping () -> FlowModel.Phase = { .idle }) {
        model.notice = text
        model.noticeAction = action
        set(.notice)
        let item = DispatchWorkItem { [weak self] in self?.set(then()) }
        noticeHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Meeting on (or updated) / off. The pill comes back after any dictation or notice.
    func setMeeting(_ m: FlowModel.Meeting?) {
        let was = model.meeting != nil
        let before = size(for: .meeting)
        guard m != model.meeting else { return }
        model.meeting = m
        if m == nil {
            model.meetingHover = false
            if model.phase == .meeting { set(.idle) }
        } else if !was || model.phase == .idle {
            if !was { model.meetingLevels = model.meetingLevels.map { _ in .init() } }
            if model.phase == .idle || model.phase == .meeting { set(.meeting) }
        } else if model.phase == .meeting, size(for: .meeting) != before {
            layout() // wrapping up, mic only, past an hour: the pill changes width
        }
    }

    /// Keeps the bar out of screen shares and recordings (`sharingType = .none`) while a meeting records.
    func hideFromCapture(_ hide: Bool) { panel.sharingType = hide ? .none : .readOnly }

    func refreshIdleVisibility() {
        model.showIdle = UserDefaults.standard.bool(forKey: Key.flowBarIdle)
        layout()
    }

    private func size(for phase: FlowModel.Phase) -> NSSize {
        switch phase {
        case .idle: return NSSize(width: 64, height: 20)
        case .listening: return NSSize(width: 132, height: 44)
        case .handsFree: return NSSize(width: 210, height: 44)
        case .typing: return NSSize(width: 124, height: 44)
        case .notice:
            let text = (model.notice as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
            return NSSize(width: min(560, text + (model.noticeAction == nil ? 48 : 110)), height: 44)
        case .meeting:
            guard let m = model.meeting else { return NSSize(width: 64, height: 20) }
            if m.wrappingUp { return NSSize(width: 168, height: 44) }
            let base: CGFloat = (m.micOnly ? 226 : 206) + (m.elapsed >= 3600 ? 22 : 0)
            guard model.meetingHover else { return NSSize(width: base, height: 44) }
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let title = min(220, (m.title as NSString).size(withAttributes: [.font: font]).width)
            return NSSize(width: base + max(title, 70) + 12, height: 44)
        }
    }

    private func layout() {
        let phase = model.phase
        if phase == .idle && !model.showIdle {
            panel.orderOut(nil)
            return
        }
        let s = size(for: phase)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.minY + 10, width: s.width, height: s.height), display: true)
        panel.orderFrontRegardless()
    }
}

private final class FlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a non-key panel must react to the first click.
private final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct FlowBarView: View {
    @ObservedObject var model: FlowModel

    private let pill = Color(red: 0.078, green: 0.082, blue: 0.094).opacity(0.94)
    private let red = Color(red: 1, green: 0.353, blue: 0.373)

    var body: some View {
        Group {
            switch model.phase {
            case .idle: idle
            case .listening: listening
            case .handsFree: handsFree
            case .typing: typing
            case .notice: notice
            case .meeting: meeting
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idle: some View {
        Button(action: model.onOpen) {
            Capsule().fill(pill)
                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .overlay(HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.55)).frame(width: 3, height: 3) } })
                .frame(width: 46, height: 10)
        }
        .buttonStyle(.plain)
        .help("Hold fn to dictate · double-tap fn or press ⇧⌥ Space for hands-free · click to open VoiceType")
        .accessibilityLabel("Open VoiceType")
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1.5).fill(Color.white)
                    .frame(width: 3, height: max(4, CGFloat(v) * 22))
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: model.levels)
        .accessibilityHidden(true)
    }

    private func shell<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .frame(maxHeight: 40)
            .background(Capsule().fill(pill))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .padding(2)
    }

    private var listening: some View {
        shell {
            Circle().fill(red).frame(width: 8, height: 8)
            bars
        }
        .accessibilityLabel("Listening. Release fn to type.")
    }

    private var handsFree: some View {
        shell {
            // No lock icon: the running timer and the stop button already say "hands-free".
            bars
            Text(String(format: "%d:%02d", model.elapsed / 60, model.elapsed % 60))
                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(.white)
            Button(action: model.onCancel) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain).help("Cancel (esc)").accessibilityLabel("Cancel dictation")
            Button(action: model.onStop) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                    .frame(width: 26, height: 26).background(Circle().fill(red))
            }
            .buttonStyle(.plain).help("Finish and type (fn)").accessibilityLabel("Finish and type")
        }
        .padding(.trailing, -8)
    }

    private var typing: some View {
        shell {
            HStack(spacing: 4) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Circle().fill(Color.white.opacity(0.6)).frame(width: 6, height: 6)
                Circle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 6)
            }
            Text("Typing…").font(.system(size: 13, weight: .medium)).foregroundColor(.white)
        }
    }

    private var meeting: some View {
        let m = model.meeting ?? .init()
        return shell {
            if m.wrappingUp {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text("Wrapping up…").font(.system(size: 13, weight: .medium)).foregroundColor(.white)
            } else {
                PulsingDot(color: red)
                meetingBars
                if model.meetingHover {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        Text("\(m.words.formatted()) words").font(.system(size: 11)).foregroundColor(.white.opacity(0.65))
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
                Text(Self.clock(m.elapsed))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(.white)
                if m.micOnly {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 11)).foregroundColor(Color(red: 0.96, green: 0.647, blue: 0.141))
                        .help("No sound from other apps: recording your mic only")
                }
                Button(action: model.onMeetingStop) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                        .frame(width: 26, height: 26).background(Circle().fill(red))
                }
                .buttonStyle(.plain).help("Stop recording the meeting (⌃⌥R)").accessibilityLabel("Stop recording the meeting")
            }
        }
        .padding(.trailing, m.wrappingUp ? 0 : -8)
        .contentShape(Rectangle())
        .onTapGesture { model.onMeetingOpen() }
        .onHover { model.meetingHover = $0 }
        .help("\(m.title) · \(m.words.formatted()) words · click for the live transcript")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(m.wrappingUp ? "Finishing the meeting transcript" : "Recording a meeting, \(Self.clock(m.elapsed))")
    }

    /// The meeting meter: rounded dots that grow with the level, teal when the others are louder,
    /// white when you are (dictation uses plain white bars).
    private var meetingBars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(model.meetingLevels.enumerated()), id: \.offset) { _, l in
                let v = max(l.me, l.others)
                Capsule().fill(l.others > l.me ? teal : Color.white.opacity(0.9))
                    .frame(width: 3, height: max(3, CGFloat(v) * 20))
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.1), value: model.meetingLevels)
        .accessibilityHidden(true)
    }

    private let teal = Color(red: 0.35, green: 0.85, blue: 0.82)

    static func clock(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var notice: some View {
        shell {
            Circle().fill(Color(red: 0.96, green: 0.647, blue: 0.141)).frame(width: 8, height: 8)
            Text(model.notice).font(.system(size: 13, weight: .medium)).foregroundColor(.white).lineLimit(1)
            if let action = model.noticeAction {
                Button(action: model.onNoticeAction) {
                    Text(action).font(.system(size: 12, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The meeting's recording light: a slow pulse. (No @State: it is a macro, and the Command Line
/// Tools have no SwiftUI macro plugin.)
private struct PulsingDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .phaseAnimator([false, true]) { dot, dim in dot.opacity(dim ? 0.35 : 1) } animation: { _ in .easeInOut(duration: 0.9) }
            .accessibilityHidden(true)
    }
}
