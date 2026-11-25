import SwiftUI
import VoiceTypeCore

/// Snippets tab: cues you say and the text VoiceType types for them.
struct SnippetsView: View {
    @ObservedObject var model: MainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Say a short cue and VoiceType types the saved text instead: an email address, a link, an intro, a prompt you use often. {date}, {time} and {day} are filled in when it’s typed. A cue works inside a sentence too, unless it’s marked “on its own”. A dictation with a snippet is typed exactly as saved (no AI polish).")
                .font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            form
            if model.snippetEditing == nil, model.snippetTrigger.isEmpty, model.snippetText.isEmpty {
                examples
            }
            if model.snippets.isEmpty {
                Text("No snippets yet.").font(.system(size: 13)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(model.snippets, id: \.self) { s in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("“\(s.trigger)”").bold()
                                    if s.alone { Text("on its own").font(.system(size: 11)).foregroundColor(.secondary) }
                                }
                                Text(s.expansion).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button { edit(s) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Edit").accessibilityLabel("Edit \(s.trigger)")
                            Button(role: .destructive) { save(model.snippets.filter { $0 != s }) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete").accessibilityLabel("Delete \(s.trigger)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Mist.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("When I say (e.g. my calendar link)", text: $model.snippetTrigger).textFieldStyle(.roundedBorder)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.snippetText)
                    .font(.system(size: 13))
                    .frame(minHeight: 54, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Mist.border))
                    .accessibilityLabel("Type this")
                if model.snippetText.isEmpty {
                    Text("Type this (e.g. https://cal.com/you)").font(.system(size: 13)).foregroundColor(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            HStack {
                Toggle("Only when I say just this", isOn: $model.snippetAlone)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .help("Off: the cue works inside a sentence too. On: only when the whole dictation is the cue.")
                if let clash = clash {
                    Text("Replaces “\(clash.trigger)”").font(.system(size: 12)).foregroundColor(.secondary)
                } else if !model.snippetTrigger.isEmpty, !SnippetSet.usable(model.snippetTrigger) {
                    Text("At least \(Snippet.minimumCueLetters) letters").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                if model.snippetEditing != nil || !model.snippetTrigger.isEmpty || !model.snippetText.isEmpty {
                    Button("Cancel") { clear() }
                }
                Button(model.snippetEditing == nil ? "Add" : "Save") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!SnippetSet.usable(model.snippetTrigger)
                              || model.snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var examples: some View {
        HStack(spacing: 8) {
            Text("Start from:").font(.system(size: 12)).foregroundColor(.secondary)
            ForEach(Snippet.examples, id: \.title) { e in
                Button(e.title) {
                    model.snippetTrigger = e.snippet.trigger
                    model.snippetText = e.snippet.expansion
                    model.snippetAlone = e.snippet.alone
                }
                .controlSize(.small)
            }
        }
    }

    /// Another snippet with the same cue (it would be replaced).
    private var clash: Snippet? {
        let key = SnippetSet.key(model.snippetTrigger)
        guard !key.isEmpty else { return nil }
        return model.snippets.first { SnippetSet.key($0.trigger) == key && $0.trigger != model.snippetEditing }
    }

    private func add() {
        let new = Snippet(model.snippetTrigger.trimmingCharacters(in: .whitespacesAndNewlines), model.snippetText, alone: model.snippetAlone)
        let key = SnippetSet.key(new.trigger)
        var list = model.snippets
        if let editing = model.snippetEditing, let i = list.firstIndex(where: { $0.trigger == editing }) {
            list[i] = new
            list = list.enumerated().filter { $0.offset == i || SnippetSet.key($0.element.trigger) != key }.map(\.element)
        } else {
            list = list.filter { SnippetSet.key($0.trigger) != key } + [new]
        }
        save(list)
        clear()
    }

    private func edit(_ s: Snippet) {
        model.snippetEditing = s.trigger
        model.snippetTrigger = s.trigger
        model.snippetText = s.expansion
        model.snippetAlone = s.alone
    }

    private func clear() {
        model.snippetEditing = nil
        model.snippetTrigger = ""
        model.snippetText = ""
        model.snippetAlone = false
    }

    private func save(_ list: [Snippet]) {
        AppSettings.snippets = list
        model.snippets = AppSettings.snippets
    }
}
