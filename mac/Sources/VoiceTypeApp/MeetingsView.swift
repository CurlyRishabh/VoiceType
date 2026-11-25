import AppKit
import SwiftUI
import VoiceTypeCore

/// The Meetings tab: start/stop, the list (search, status), and one meeting's transcript.
struct MeetingsView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @ObservedObject var store: MeetingStore
    @ObservedObject var meetings: MeetingController

    var body: some View {
        if let id = model.openMeeting, let entry = store.entry(id) {
            MeetingDetailView(app: app, model: model, store: store, meetings: meetings, entry: entry)
                .id(entry.info.startedAt) // another meeting = fresh view state (a rename keeps it)
        } else {
            list
        }
    }

    private var list: some View {
        let items = store.entries.filter { store.matches($0, model.meetingQuery) }
        return VStack(spacing: 0) {
            RecordCard(meetings: meetings, start: { app.toggleMeetingRecording() }) { if let id = meetings.currentID { open(id) } }.padding(.horizontal, 24).padding(.top, 16)
            if !store.entries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary).accessibilityHidden(true)
                    TextField("Search meetings and transcripts", text: $model.meetingQuery).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Mist.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Mist.border))
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
            }
            if items.isEmpty {
                VStack(spacing: 6) {
                    Text(store.entries.isEmpty ? "No meetings yet" : "No matches").font(.system(size: 15, weight: .semibold))
                    if store.entries.isEmpty {
                        Text("Transcripts land here, with Copy for AI to paste into Claude or Codex for a summary.")
                            .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { e in
                            MeetingRow(entry: e, live: e.id == meetings.currentID ? meetings : nil)
                                .contentShape(Rectangle())
                                .onTapGesture { open(e) }
                                .contextMenu { menu(e) }
                            if e.id != items.last?.id { Divider().padding(.horizontal, 12) }
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Mist.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Mist.border))
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
            }
        }
    }

    private func open(_ id: String) {
        if let e = store.entry(id) { open(e) }
    }

    private func open(_ e: MeetingStore.Entry) {
        model.meetingTitleDraft = e.info.title
        model.meetingFind = ""
        model.meetingFindIndex = 0
        model.openMeeting = e.id
    }

    @ViewBuilder private func menu(_ e: MeetingStore.Entry) -> some View {
        Button("Open") { open(e) }
        if e.info.status.hasTranscript {
            Button("Copy transcript") { MeetingActions.copy(MeetingRender.plain(e.info, lines: store.lines(e))) }
            Button("Copy for AI") { MeetingActions.copy(MeetingRender.forAI(e.info, lines: store.lines(e))) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.folder]) }
    }
}

enum MeetingActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Start / stop at the top of the tab, with what is going on.
private struct RecordCard: View {
    @ObservedObject var meetings: MeetingController
    /// Like the shortcut: during a call, records that call.
    let start: () -> Void
    /// Opens the meeting being recorded (its live transcript).
    var showLive: () -> Void = {}
    private let red = Color(red: 1, green: 0.353, blue: 0.373)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                switch meetings.phase {
                case .idle:
                    Image(systemName: "record.circle").font(.system(size: 22)).foregroundColor(red).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Record a meeting").font(.system(size: 15, weight: .semibold))
                        Text("Your mic is “Me”, the sound of other apps is “Others”. Transcribed on this Mac while you talk.\(KeyMonitor.meetingShortcutOn ? " Shortcut: \(KeyMonitor.meetingShortcutTitle)." : "")")
                            .font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Start recording") { start() }.keyboardShortcut("r", modifiers: [.command])
                case .recording:
                    Circle().fill(red).frame(width: 10, height: 10).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recording · \(FlowBarView.clock(meetings.elapsed))").font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Text("\(meetings.words.formatted()) words so far. Stop to finish the transcript.")
                            .font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Live transcript") { showLive() }
                    Button("Stop") { meetings.stop() } // no default-button shortcut: Return in a text field must not end the meeting
                case .finishing:
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wrapping up…").font(.system(size: 15, weight: .semibold))
                        Text("Transcribing the last few seconds.").font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                }
            }
            if meetings.phase == .recording, meetings.systemAudio == .silent || meetings.systemAudio == .unavailable {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash.fill").foregroundColor(.orange).accessibilityHidden(true)
                    Text(meetings.systemAudio == .unavailable ? "Recording your mic only: other apps’ sound couldn’t be captured."
                         : "Recording your mic only: no sound from other apps yet. If others are talking, allow System Audio Recording.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Turn on…") { SystemAudioPermission.openSettings() }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Mist.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Mist.border))
    }
}

private struct MeetingRow: View {
    let entry: MeetingStore.Entry
    /// The meeting recording right now (live length and words).
    let live: MeetingController?

    var body: some View {
        let info = entry.info
        let seconds = live.map { Double($0.elapsed) } ?? info.durationSeconds
        let words = live.map(\.words) ?? info.wordCount
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text([MeetingDates.relative(info.startedAt), MeetingDates.duration(seconds), "\(words.formatted()) words"].joined(separator: " · "))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            StatusChip(status: live?.phase == .finishing ? .transcribing : info.status)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct StatusChip: View {
    let status: MeetingInfo.Status

    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .recording: return ("Recording", .red)
            case .transcribing: return ("Transcribing", .orange)
            case .ready: return ("Ready", .green)
            case .partial: return ("Partial", .orange)
            case .failed: return ("Failed", .red)
            }
        }()
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundColor(color)
    }
}

/// One meeting: title (editable), facts, actions, find, and the transcript.
private struct MeetingDetailView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @ObservedObject var store: MeetingStore
    @ObservedObject var meetings: MeetingController
    let entry: MeetingStore.Entry

    private var isCurrent: Bool { entry.id == meetings.currentID }
    private var hasAudio: Bool { !isCurrent && !MeetingFiles.audioFiles(entry.folder).isEmpty }

    var body: some View {
        let info = entry.info
        let lines = info.status.hasTranscript ? store.lines(entry) : []
        let matches = Self.matches(lines, model.meetingFind)
        let current = matches.isEmpty ? nil : matches[((model.meetingFindIndex % matches.count) + matches.count) % matches.count]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { rename(); model.openMeeting = nil } label: { Label("Meetings", systemImage: "chevron.left") } // a title typed without Return
                    .buttonStyle(.link)
                Spacer()
                StatusChip(status: isCurrent && meetings.phase == .finishing ? .transcribing : info.status)
            }
            TextField("Title", text: $model.meetingTitleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold))
                .onSubmit { rename() }
            Text(facts(info)).font(.system(size: 12)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("Copy transcript") { MeetingActions.copy(MeetingRender.plain(currentInfo, lines: lines)) }
                    .disabled(!info.status.hasTranscript)
                Button("Copy for AI") { MeetingActions.copy(MeetingRender.forAI(currentInfo, lines: lines)) }
                    .disabled(!info.status.hasTranscript)
                    .help("The transcript with instructions for Claude or Codex: summary, decisions, action items, open questions, with timestamps")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder.appendingPathComponent(MeetingFiles.transcriptMarkdown)]) }
                if hasAudio {
                    Menu("Re-transcribe") {
                        Button("English") { meetings.retranscribe(entry, language: "en") }
                        Button("Hindi") { meetings.retranscribe(entry, language: "hi") }
                        Button("English + Hindi") { meetings.retranscribe(entry, language: "auto") }
                    }
                    .fixedSize()
                    .disabled(!meetings.canRetranscribe(entry))
                    .help("Transcribe the kept audio again, for example in another language. Your notes stay.")
                    Button("Find speakers") { meetings.identifySpeakers(entry.id, deleteAudioAfter: false) }
                        .disabled(!meetings.canIdentifySpeakers(entry))
                        .help("Tell the other people on the call apart by voice (Speaker 1, Speaker 2…).")
                    Button("Delete audio") { meetings.deleteAudio(entry) }
                        .disabled(isCurrent || entry.id == meetings.recoveringID || entry.id == meetings.identifyingID)
                        .help("Delete mic.wav and system.wav now. The transcript and notes stay; re-transcribing is no longer possible.")
                }
                Spacer()
                // Anything but the meeting being recorded or transcribed right now (a crashed one can go).
                Button("Delete…", role: .destructive) { model.confirmDeleteMeeting = true }
                    .disabled(isCurrent || entry.id == meetings.recoveringID || entry.id == meetings.identifyingID)
            }
            .controlSize(.small)
            if entry.id == meetings.identifyingID {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Telling the other speakers apart…").font(.system(size: 12)).foregroundColor(.secondary)
                }
            } else if info.speakers > 1 {
                Text("\(info.speakers) other speakers told apart by voice. Right-click a speaker’s name to rename them.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            if info.status == .partial, let error = info.error {
                Label("\(error). The audio is kept in the meeting folder.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if info.status.hasTranscript, !lines.isEmpty { findBar(matches.count, current: current.flatMap { matches.firstIndex(of: $0) }) }
            Divider()
            content(info, lines, matches: Set(matches), current: current)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .confirmationDialog("Delete “\(info.title)”?", isPresented: $model.confirmDeleteMeeting) {
            Button("Delete meeting", role: .destructive) {
                model.openMeeting = nil
                store.delete(entry)
            }
        } message: {
            Text("The transcript and any audio in its folder are deleted. This can’t be undone.")
        }
    }

    /// The title as typed, even before Return (so a copy right after editing has it).
    private var currentInfo: MeetingInfo {
        var i = entry.info
        let t = model.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { i.title = t }
        return i
    }

    private func rename() {
        if isCurrent {
            meetings.rename(to: model.meetingTitleDraft)
            return
        }
        let inUse = meetings.isBusy(entry.id)
        store.rename(entry, to: model.meetingTitleDraft, folderInUse: inUse) // the open view follows via onRename
    }

    private func facts(_ info: MeetingInfo) -> String {
        var parts = [MeetingDates.relative(info.startedAt)]
        if isCurrent && meetings.phase == .recording {
            parts.append(FlowBarView.clock(meetings.elapsed) + " so far")
        } else {
            parts.append(MeetingDates.duration(info.durationSeconds))
            parts.append("\(info.wordCount.formatted()) words")
        }
        if !info.model.isEmpty { parts.append(info.model) }
        if info.systemAudio == .silent || info.systemAudio == .unavailable { parts.append("mic only") }
        return parts.joined(separator: " · ")
    }

    private func findBar(_ count: Int, current: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary).accessibilityHidden(true)
            TextField("Find in transcript", text: $model.meetingFind).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit { model.meetingFindIndex += 1 }
            if !model.meetingFind.isEmpty {
                Text(count == 0 ? "No matches" : "\((current ?? 0) + 1) of \(count)")
                    .font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                Button { model.meetingFindIndex -= 1 } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(count == 0).accessibilityLabel("Previous match")
                Button { model.meetingFindIndex += 1 } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(count == 0).accessibilityLabel("Next match")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Mist.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mist.border))
    }

    static func matches(_ lines: [TranscriptLine], _ query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return lines.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }

    @ViewBuilder
    private func content(_ info: MeetingInfo, _ lines: [TranscriptLine], matches: Set<Int>, current: Int?) -> some View {
        switch info.status {
        case .recording where isCurrent, .transcribing where isCurrent:
            LiveTranscript(meetings: meetings)
        case .recording, .transcribing:
            if isCurrent || entry.id == meetings.recoveringID {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.system(size: 13)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("Interrupted", "This recording was cut off (the app quit or crashed). VoiceType transcribes it at the next launch when the speech model is available.")
            }
        case .failed:
            placeholder("Transcription failed", (info.error ?? "Unknown error.") + (info.audioKept ? " The audio is still in the meeting folder." : ""))
        case .ready, .partial:
            if lines.isEmpty {
                placeholder("No speech", "Nothing was transcribed in this recording.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                LineRow(line: line, highlight: line.id == current ? .current : matches.contains(line.id) ? .match : .none,
                                        renameVoice: { askSpeakerName($0, current: line.label) }).id(line.id)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .onChange(of: current) { _, c in if let c { withAnimation { proxy.scrollTo(c, anchor: .center) } } }
                }
            }
            NoteField(placeholder: "Add a note to this meeting (Return to save)") { store.addNote(entry, $0) }
        }
    }

    /// "Speaker 2" → a name, in a small alert (no SwiftUI state needed).
    private func askSpeakerName(_ voice: Int, current: String) {
        let alert = NSAlert()
        alert.messageText = "Name Speaker \(voice)"
        alert.informativeText = "Used in this meeting’s transcript and in Copy for AI. Leave empty for “Speaker \(voice)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current == "Speaker \(voice)" ? "" : current
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.renameSpeaker(entry, voice: voice, to: field.stringValue)
    }

    private func placeholder(_ title: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineRow: View {
    enum Highlight { case none, match, current }
    let line: TranscriptLine
    let highlight: Highlight
    /// Rename one of the others told apart by voice (absent in the live view).
    var renameVoice: ((Int) -> Void)? = nil

    private static let others = Color(red: 0.13, green: 0.55, blue: 0.53)
    /// One colour per voice among the others.
    private static let voices: [Color] = [others, Color(red: 0.55, green: 0.35, blue: 0.75), Color(red: 0.75, green: 0.45, blue: 0.15),
                                          Color(red: 0.25, green: 0.45, blue: 0.8), Color(red: 0.7, green: 0.3, blue: 0.45)]

    private var color: Color {
        if line.isNote { return .orange }
        if line.channel == .me { return Mist.accent }
        return line.voice.map { Self.voices[($0 - 1) % Self.voices.count] } ?? Self.others
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MeetingTranscript.timestamp(line.start))
                .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(line.isNote ? "Note" : line.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .frame(width: line.voice == nil ? 48 : 78, alignment: .leading)
                .contextMenu {
                    if let v = line.voice, let renameVoice { Button("Rename \(line.label)…") { renameVoice(v) } }
                }
                .help(line.voice == nil ? "" : "Right-click to rename")
            Text(line.text).font(.system(size: 14)).italic(line.isNote).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            highlight == .current ? Mist.accent.opacity(0.2) : highlight == .match ? Mist.tile : Color.clear))
        .accessibilityElement(children: .combine)
    }
}

/// The meeting being recorded: what has been transcribed so far (a few seconds behind the talk),
/// following the newest line unless you scroll up, with a box for notes.
private struct LiveTranscript: View {
    @ObservedObject var meetings: MeetingController
    @StateObject private var ui = LiveUI()

    var body: some View {
        let lines = meetings.liveLines
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if meetings.phase == .finishing {
                    ProgressView().controlSize(.small)
                    Text("Wrapping up: the last few seconds are being transcribed").font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Live · a few seconds behind").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Follow", isOn: $ui.follow).toggleStyle(.checkbox).font(.system(size: 12))
            }
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Text("Listening…").font(.system(size: 15, weight: .semibold))
                    Text("Lines appear here a few seconds after each sentence.").font(.system(size: 13)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { LineRow(line: $0, highlight: .none).id($0.id) }
                            Color.clear.frame(height: 1).id(-1)
                        }
                        .padding(.bottom, 8)
                    }
                    // Segments, not lines: a long turn grows one line without adding any.
                    .onChange(of: meetings.liveSegments.count + meetings.notes.count) { _, _ in
                        if ui.follow { withAnimation { proxy.scrollTo(-1, anchor: .bottom) } }
                    }
                    .onAppear { proxy.scrollTo(-1, anchor: .bottom) }
                }
            }
            LiveNoteField(meetings: meetings)
        }
    }
}

/// One line for typing a note; Return saves it and clears the box.
private struct NoteField: View {
    let placeholder: String
    let save: (String) -> Void
    @StateObject private var draft = LiveUI()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundColor(.orange).accessibilityHidden(true)
            TextField(placeholder, text: $draft.text).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit {
                    let t = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    save(t)
                    draft.text = ""
                }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Mist.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mist.border))
    }
}

/// View-local state (the app is built without the SwiftUI macro plugin, so no @State).
private final class LiveUI: ObservableObject {
    @Published var follow = true
    @Published var text = ""
}

/// The live note box; its text lives in the controller, so a meeting that stops mid-sentence still
/// gets the note (saved when the transcript is written).
private struct LiveNoteField: View {
    @ObservedObject var meetings: MeetingController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundColor(.orange).accessibilityHidden(true)
            TextField("Type a note, Return to add it at this moment", text: $meetings.noteDraft).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit {
                    meetings.addNote(meetings.noteDraft)
                    meetings.noteDraft = ""
                }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Mist.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mist.border))
    }
}
