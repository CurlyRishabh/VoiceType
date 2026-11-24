import AppKit
import AVFoundation
import SwiftUI
import VoiceTypeCore

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case languages, microphone, typing, key, models, tryIt
        var title: String {
            switch self {
            case .languages: return "Languages"
            case .microphone: return "Microphone"
            case .typing: return "Typing"
            case .key: return "Dictation key"
            case .models: return "Models"
            case .tryIt: return "Try it"
            }
        }

        func isDone(_ app: AppDelegate) -> Bool {
            switch self {
            case .languages: return true // there is always a valid choice (English by default)
            case .microphone: return Permissions.isGranted(.microphone)
            case .typing: return Permissions.isGranted(.accessibility)
            case .key: return TriggerKey.current == .optionSpace || Permissions.isGranted(.inputMonitoring)
            case .models: return app.models.isReady(.vad) && (app.models.isReady(.moonshine) || app.models.isReady(.whisper))
            case .tryIt: return !app.history.items.isEmpty
            }
        }
    }

    /// Saved, so setup picks up where it was after macOS's "Quit & Reopen" for Input Monitoring.
    @Published var step: Step = Step(rawValue: UserDefaults.standard.integer(forKey: Key.onboardingStep)) ?? .languages {
        didSet { UserDefaults.standard.set(step.rawValue, forKey: Key.onboardingStep) }
    }
    @Published var refresh = 0
    @Published var tryText = ""
    @Published var importReport = ""
}

struct OnboardingView: View {
    let app: AppDelegate
    @ObservedObject var model: OnboardingModel
    @AppStorage(Key.language) var language = "en"
    @AppStorage(Key.script) var script = "latin"

    var body: some View {
        let _ = model.refresh
        VStack(spacing: 26) {
            HStack(spacing: 8) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                    let done = s.isDone(app)
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
                case .languages: languages
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
                if model.step != .languages {
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

    // MARK: Languages

    private var languages: some View {
        let picked = LanguageSelection.languages(for: language)
        return VStack(alignment: .leading, spacing: 16) {
            step("Which languages do you speak?",
                 "Pick every language you dictate in. Pick both if you mix them, like Hinglish: VoiceType then works out which one you’re speaking each time.",
                 done: false) { EmptyView() }
            VStack(spacing: 0) {
                ForEach(LanguageSelection.codes, id: \.self) { code in
                    if code != LanguageSelection.codes.first { Divider() }
                    languageRow(code, picked)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            if picked.contains("hi") {
                HStack {
                    Text("Write Hindi in").font(.system(size: 13))
                    Spacer()
                    Picker("Write Hindi in", selection: $script) {
                        Text("Latin: kal meeting hai").tag("latin")
                        Text("देवनागरी: कल मीटिंग है").tag("devanagari")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            Text("You can change this any time in Settings or from the menu bar.")
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func languageRow(_ code: String, _ picked: Set<String>) -> some View {
        let on = picked.contains(code)
        let isOnlyPick = on && picked.count == 1
        return Button {
            var next = picked
            if on { next.remove(code) } else { next.insert(code) }
            // nil = nothing left picked: keep the last language.
            if let setting = LanguageSelection.setting(for: next) { language = setting }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundColor(on ? .accentColor : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(code == "hi" ? "हिंदी (Hindi)" : "English").font(.system(size: 14, weight: .semibold))
                    Text(code == "hi" ? "Also Hinglish: Hindi mixed with English words" : "Picked on its own, VoiceType never has to guess the language")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "on" : "off")
        .help(isOnlyPick ? "Pick another language before turning this one off" : "")
    }

    // MARK: Permissions

    /// "VoiceType is already in the list; switch it on." Shown once VoiceType has asked.
    @ViewBuilder private func switchItOnHint(_ kind: Permissions.Kind, _ list: String) -> some View {
        if Permissions.hasAsked(kind) && !Permissions.isGranted(kind) {
            VStack(alignment: .leading, spacing: 4) {
                Label("VoiceType is already in the \(list) list. Switch it on there; you don’t need to add it.",
                      systemImage: "info.circle")
                Text("Switched on but still not working? Rebuilt copies of VoiceType count as a new app: select VoiceType, remove it with −, then press the button again.")
                    .foregroundColor(.secondary).padding(.leading, 22)
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 14) {
            step("Let VoiceType hear you",
                 "Audio is processed on this Mac and discarded right after it is turned into text. The app cannot reach the internet.",
                 done: Permissions.isGranted(.microphone)) {
                if !Permissions.isGranted(.microphone) {
                    Button(Permissions.hasAsked(.microphone) ? "Open System Settings" : "Allow microphone") {
                        Permissions.request(.microphone) { model.refresh += 1 }
                    }
                }
            }
            switchItOnHint(.microphone, "Microphone")
            systemAudio
        }
    }

    /// Optional, for meeting recording: the other side of a call is the sound of other apps.
    private var systemAudio: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recording meetings? (optional)", systemImage: "record.circle").font(.system(size: 13, weight: .semibold))
            Text("To transcribe the other people on a call, VoiceType also records the sound of other apps. macOS asks for System Audio Recording the first time you record a meeting (\(KeyMonitor.meetingShortcutTitle)); it is listed under Screen & System Audio Recording.")
                .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(SystemAudioPermission.statusText).font(.system(size: 12))
                    .foregroundColor(SystemAudioPermission.lastState == .silent ? .orange : .secondary)
                Spacer()
                Button("Open System Settings") { SystemAudioPermission.openSettings() }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .padding(.top, 6)
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 14) {
            step("Let VoiceType type for you",
                 "Accessibility lets VoiceType press ⌘V in the app you’re typing in, and look at the text around your cursor for spacing and capitals. Without it, text is copied and you paste it yourself.",
                 done: Permissions.isGranted(.accessibility)) {
                if !Permissions.isGranted(.accessibility) {
                    Button(Permissions.hasAsked(.accessibility) ? "Open System Settings" : "Allow typing") {
                        Permissions.request(.accessibility) { model.refresh += 1 }
                    }
                }
            }
            switchItOnHint(.accessibility, "Accessibility")
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 16) {
            step("Make fn start dictation",
                 "Hold fn to talk; double-tap it, or press ⇧⌥ Space, for hands-free. VoiceType needs Input Monitoring to notice fn in other apps. It only reacts to fn and esc and never records what you type.",
                 done: model.step.isDone(app)) {
                if TriggerKey.current != .optionSpace && !Permissions.isGranted(.inputMonitoring) {
                    Button(Permissions.hasAsked(.inputMonitoring) ? "Open System Settings" : "Allow Input Monitoring") {
                        Permissions.request(.inputMonitoring) { app.applyTrigger(); model.refresh += 1 }
                    }
                }
            }
            if TriggerKey.current != .optionSpace { switchItOnHint(.inputMonitoring, "Input Monitoring") }
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

    // MARK: Models and trying it

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            step("Get the speech model",
                 "One file (\(KnownModels.recommended.sizeText)). VoiceType never goes online, so your browser downloads it:\n1. Click Download and wait for it to finish.\n2. Click Import and choose \(KnownModels.recommended.fileName) in Downloads.\nVoiceType checks the file and copies it in; you can delete the download afterwards.",
                 done: model.step.isDone(app)) {
                Button("Download (\(KnownModels.recommended.sizeText))") { app.downloadModel() }
                Button("Import…") { app.importModels { model.importReport = $0; model.refresh += 1 } }
            }
            Label(app.models.isReady(.whisper) ? "Speech model ready" : "Speech model not imported yet",
                  systemImage: app.models.isReady(.whisper) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(app.models.isReady(.whisper) ? .primary : .secondary)
            if !model.importReport.isEmpty { Text(model.importReport).font(.caption).foregroundColor(.secondary) }
        }
    }

    private var tryIt: some View {
        let key = TriggerKey.current == .fn ? "fn" : TriggerKey.current.title
        let picked = LanguageSelection.languages(for: language)
        let phrase = picked == ["hi"] ? "“Namaste, yeh meri pehli dictation hai.”" : "“Hello, this is my first dictation, full stop.”"
        return VStack(alignment: .leading, spacing: 14) {
            step("Try it", "Click in the box, hold \(key) and say \(phrase) Release to type it. Then try double-tapping \(key) (or pressing ⇧⌥ Space) for hands-free.",
                 done: model.step.isDone(app)) {
                EmptyView()
            }
            TextEditor(text: $model.tryText)
                .font(.system(size: 15))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
    }
}
