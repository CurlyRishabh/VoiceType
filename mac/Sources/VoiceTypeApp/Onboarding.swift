import AppKit
import AVFoundation
import SwiftUI
import VoiceTypeCore

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case microphone, typing, key, models, tryIt
        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .typing: return "Typing permission"
            case .key: return "Dictation key"
            case .models: return "Models"
            case .tryIt: return "Try it"
            }
        }
    }

    @Published var step: Step = .microphone
    @Published var refresh = 0
    @Published var tryText = ""
    @Published var importReport = ""
}

struct OnboardingView: View {
    let app: AppDelegate
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let _ = model.refresh
        VStack(spacing: 26) {
            HStack(spacing: 8) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                    let done = isDone(s)
                    let current = s == model.step
                    HStack(spacing: 6) {
                        if done && !current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                        Text(current ? "\(s.rawValue + 1) · \(s.title)" : s.title)
                    }
                    .font(.system(size: 12, weight: current ? .semibold : .medium))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(current ? Color.accentColor : (done ? Color.green.opacity(0.15) : Color.primary.opacity(0.07))))
                    .foregroundColor(current ? .white : (done ? Color(red: 0.18, green: 0.42, blue: 0.23) : .secondary))
                    .onTapGesture { model.step = s }
                }
            }
            Group {
                switch model.step {
                case .microphone: microphone
                case .typing: typing
                case .key: key
                case .models: models
                case .tryIt: tryIt
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                if model.step != .microphone {
                    Button("Back") { model.step = OnboardingModel.Step(rawValue: model.step.rawValue - 1)! }
                }
                Spacer()
                if model.step == .tryIt {
                    Button("Finish") { app.finishOnboarding() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { model.step = OnboardingModel.Step(rawValue: model.step.rawValue + 1)! }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(32)
        .frame(width: 720, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh += 1 }
    }

    private func isDone(_ s: OnboardingModel.Step) -> Bool {
        switch s {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .typing: return Inserter.isTrusted
        case .key: return TriggerKey.current == .optionSpace || KeyMonitor.hasInputMonitoring
        case .models: return app.models.isReady(.vad) && (app.models.isReady(.moonshine) || app.models.isReady(.whisper))
        case .tryIt: return !app.history.items.isEmpty
        }
    }

    private func step(_ title: String, _ body: String, done: Bool, @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 26, weight: .bold))
                if done { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 20)) }
            }
            Text(body).font(.system(size: 15)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) { actions() }.padding(.top, 4)
        }
    }

    private var microphone: some View {
        step("Let VoiceType hear you",
             "Audio is processed on this Mac and discarded right after it is turned into text. The app cannot reach the internet.",
             done: isDone(.microphone)) {
            Button("Allow microphone") {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { model.refresh += 1 } }
            }
            Button("Open Privacy settings") { openPrivacy("Privacy_Microphone") }
        }
    }

    private var typing: some View {
        step("Let VoiceType type for you",
             "Accessibility lets VoiceType press ⌘V in the app you’re typing in, and look at the text around your cursor for spacing and capitals. Turn VoiceType on in the list. Without it, text is copied and you paste it yourself.",
             done: isDone(.typing)) {
            Button("Allow typing") { Inserter.requestTrust(); openPrivacy("Privacy_Accessibility") }
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 16) {
            step("Make fn start dictation",
                 "Hold fn to talk; double-tap it for hands-free. VoiceType needs Input Monitoring to notice fn in other apps. It only reacts to fn and esc and never records what you type.",
                 done: isDone(.key)) {
                Button("Allow Input Monitoring") { KeyMonitor.requestInputMonitoring(); openPrivacy("Privacy_ListenEvent"); app.applyTrigger() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("System Settings → Keyboard → “Press fn key to”").font(.system(size: 13)).foregroundColor(.secondary)
                HStack {
                    switch FnKeySetting.isDoNothing {
                    case .some(true): Label("Set to Do Nothing", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    case .some(false): Label("Change it to Do Nothing", systemImage: "exclamationmark.circle.fill").foregroundColor(.orange)
                    case .none: Label("Set it to Do Nothing, or fn will also open emoji", systemImage: "info.circle").foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Open Keyboard Settings") { FnKeySetting.openKeyboardSettings() }
                }
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
            HStack(spacing: 16) {
                Button("No fn key? Use right ⌥") { setTrigger(.rightOption) }.buttonStyle(.link)
                Button("Use ⌥ Space (no permission needed)") { setTrigger(.optionSpace) }.buttonStyle(.link)
            }
            .font(.system(size: 13))
            Text("Current key: \(TriggerKey.current.title)").font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func setTrigger(_ t: TriggerKey) {
        UserDefaults.standard.set(t.rawValue, forKey: Key.trigger)
        app.applyTrigger()
        model.refresh += 1
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            step("Add the speech models",
                 "Choose the folder that holds vad, moonshine and whisper (for example voiceapk/models). The files are copied into VoiceType; nothing is downloaded.",
                 done: isDone(.models)) {
                Button("Import models folder…") { app.importModels { model.importReport = $0; model.refresh += 1 } }
            }
            ForEach(ModelSlot.allCases, id: \.self) { slot in
                Label(slot.title, systemImage: app.models.isReady(slot) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(app.models.isReady(slot) ? .primary : .secondary)
            }
            if !model.importReport.isEmpty { Text(model.importReport).font(.caption).foregroundColor(.secondary) }
        }
    }

    private var tryIt: some View {
        let key = TriggerKey.current == .fn ? "fn" : TriggerKey.current.title
        return VStack(alignment: .leading, spacing: 14) {
            step("Try it", "Click in the box, hold \(key) and say “Hello, this is my first dictation, full stop.” Release to type it. Then try double-tapping \(key) for hands-free.", done: isDone(.tryIt)) {
                EmptyView()
            }
            TextEditor(text: $model.tryText)
                .font(.system(size: 15))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
    }
}
