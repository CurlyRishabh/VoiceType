import AppKit
import SwiftUI
import VoiceTypeCore

/// Scratchpad: quick notes kept on this Mac (JSON next to History). Dictate into a note like into
/// any other app; it saves as you go.
final class ScratchpadStore: ObservableObject {
    struct Note: Codable, Identifiable, Hashable {
        var id = UUID()
        var text: String
        var created: Date
        var modified: Date

        /// The first line with words in it.
        var title: String {
            text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                .map { String($0.prefix(80)) } ?? "New note"
        }
    }

    @Published private(set) var notes: [Note] = []
    @Published var selected: UUID?
    @Published var query = ""
    /// Bumped to put the cursor in the open note (a new note, or opened from the menu bar).
    @Published var focusRequest = 0

    private let file: URL
    private var pendingSave: DispatchWorkItem?
    /// The file was there but unreadable and couldn't be set aside: never saved over.
    private var readOnly = false
    /// Changed since the last save (a second copy of the app that quits at once writes nothing).
    private var dirty = false
    private var saveFailed = false
    /// Saving failed (or can't be done): shown to the user once.
    var onSaveFailed: (() -> Void)?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceType")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("scratchpad.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = file.deletingLastPathComponent().appendingPathComponent("scratchpad-unreadable-\(stamp).json")
        if let data = try? Data(contentsOf: file), let (loaded, dropped) = SafeJSON.decodeArray(Note.self, from: data) {
            notes = loaded.sorted { $0.modified > $1.modified }
            if dropped > 0 {
                // Keep the original beside it, then save the readable notes.
                if (try? FileManager.default.copyItem(at: file, to: copy)) != nil { dirty = true } else { readOnly = true }
                Diagnostics.log("scratchpad: \(dropped) unreadable notes skipped; \(readOnly ? "not saving over the file" : "original kept as \(copy.lastPathComponent)")")
            }
        } else {
            // Keep what's there; start afresh beside it rather than saving over it.
            if (try? FileManager.default.moveItem(at: file, to: copy)) == nil { readOnly = true }
            Diagnostics.log("scratchpad: scratchpad.json unreadable; \(readOnly ? "left alone, not saving" : "moved to \(copy.lastPathComponent)")")
        }
        selected = notes.first?.id
    }

    var current: Note? { notes.first { $0.id == selected } }

    var shown: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? notes : notes.filter { $0.text.lowercased().contains(q) }
    }

    /// A new empty note at the top, opened with the cursor in it. An empty note already on top is reused.
    func newNote() {
        query = ""
        if let top = notes.first, top.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selected = top.id
        } else {
            let now = Date()
            let n = Note(text: "", created: now, modified: now)
            notes.insert(n, at: 0)
            selected = n.id
        }
        focusRequest += 1
    }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = Date()
        if i != 0 { notes.insert(notes.remove(at: i), at: 0) } // most recently edited first
        dirty = true
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: i)
        if selected == id { selected = notes.indices.contains(i) ? notes[i].id : notes.last?.id }
        dirty = true
        saveNow()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// Also on quit, so the last keystrokes aren't lost.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard dirty else { return }
        guard !readOnly else { return reportFailure() }
        // Empty notes aren't kept.
        let keep = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do {
            try JSONEncoder().encode(keep).write(to: file, options: [.atomic, .completeFileProtection])
            dirty = false
            saveFailed = false
        } catch {
            Diagnostics.log("scratchpad: couldn't save (\(error.localizedDescription))")
            reportFailure()
        }
    }

    private func reportFailure() {
        guard !saveFailed else { return }
        saveFailed = true
        onSaveFailed?()
    }
}

struct ScratchpadView: View {
    let app: AppDelegate
    @ObservedObject var notes: ScratchpadStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            editor
        }
        .onDisappear { notes.saveNow() }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search notes", text: $notes.query).textFieldStyle(.roundedBorder)
                Button { notes.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .help("New note (⌘N)").accessibilityLabel("New note")
                    .keyboardShortcut("n", modifiers: [.command])
            }
            if notes.shown.isEmpty {
                Text(notes.notes.isEmpty ? "No notes yet." : "No matches").font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                List(selection: $notes.selected) {
                    ForEach(notes.shown) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(n.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        .tag(n.id)
                        .contextMenu { Button("Delete", role: .destructive) { notes.delete(n.id) } }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var editor: some View {
        if let note = notes.current {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Edited \(note.modified.formatted(date: .abbreviated, time: .shortened)) · \(note.text.split(whereSeparator: \.isWhitespace).count) words")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button { copy(note.text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy the note").accessibilityLabel("Copy the note")
                    Button(role: .destructive) { notes.delete(note.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete the note").accessibilityLabel("Delete the note")
                }
                NoteEditor(text: note.text, focusRequest: notes.focusRequest) { notes.update(note.id, text: $0) }
                    .id(note.id)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        } else {
            VStack(spacing: 10) {
                Text("For quick thoughts to come back to").font(.system(size: 15, weight: .semibold))
                Text("Start a note and dictate into it with \(TriggerKey.current.short), like in any app. Notes stay on this Mac.")
                    .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("New note") { notes.newNote() }.keyboardShortcut(.defaultAction)
            }
            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A plain NSTextView (SwiftUI's TextEditor can't be focused from code without macros the Command
/// Line Tools lack): pastes from dictation land in it like in any other app.
private struct NoteEditor: NSViewRepresentable {
    let text: String
    let focusRequest: Int
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        tv.delegate = context.coordinator
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        tv.drawsBackground = false
        focusIfAsked(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.onChange = onChange
        if tv.string != text, !context.coordinator.editing { tv.string = text }
        focusIfAsked(tv)
    }

    /// The cursor goes into the note only when asked (a new note, the menu bar), not each time
    /// another note is picked in the list (that would take the arrow keys away from the list).
    private static var focusHandled = 0
    private func focusIfAsked(_ tv: NSTextView) {
        guard focusRequest != Self.focusHandled else { return }
        Self.focusHandled = focusRequest
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var editing = false
        init(_ onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            editing = true
            onChange(tv.string)
            editing = false
        }
    }
}
