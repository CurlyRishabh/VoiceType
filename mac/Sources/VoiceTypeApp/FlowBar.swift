import AppKit
import SwiftUI

/// What the flow bar shows.
final class FlowModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, handsFree, typing, notice }

    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: 12)
    @Published var elapsed = 0
    @Published var notice = ""
    @Published var noticeAction: String?
    @Published var showIdle = true

    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpen: () -> Void = {}
    var onNoticeAction: () -> Void = {}

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
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
        layout()
    }

    func set(_ phase: FlowModel.Phase) {
        if phase != .notice { noticeHide?.cancel() }
        if phase == .listening || phase == .handsFree, model.phase != .listening, model.phase != .handsFree {
            model.levels = model.levels.map { _ in 0 }
        }
        withAnimation(.easeOut(duration: 0.15)) { model.phase = phase }
        layout()
    }

    func notice(_ text: String, action: String? = nil, seconds: TimeInterval = 4) {
        model.notice = text
        model.noticeAction = action
        set(.notice)
        let item = DispatchWorkItem { [weak self] in self?.set(.idle) }
        noticeHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func refreshIdleVisibility() {
        model.showIdle = UserDefaults.standard.bool(forKey: Key.flowBarIdle)
        layout()
    }

    private func size(for phase: FlowModel.Phase) -> NSSize {
        switch phase {
        case .idle: return NSSize(width: 64, height: 20)
        case .listening: return NSSize(width: 132, height: 44)
        case .handsFree: return NSSize(width: 230, height: 44)
        case .typing: return NSSize(width: 124, height: 44)
        case .notice:
            let text = (model.notice as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
            return NSSize(width: min(560, text + (model.noticeAction == nil ? 48 : 110)), height: 44)
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
        .help("Hold fn to dictate · double-tap for hands-free · click to open VoiceType")
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
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                .accessibilityLabel("Hands-free")
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
