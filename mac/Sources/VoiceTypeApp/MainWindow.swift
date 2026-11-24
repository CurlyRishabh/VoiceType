import AppKit
import AVFoundation
import Charts
import SwiftUI
import VoiceTypeCore

/// Tabs + shared view state (ObservableObject instead of @State: the Command Line Tools toolchain
/// has no SwiftUI macro plugin).
final class MainModel: ObservableObject {
    enum Section: Int, CaseIterable, Identifiable {
        case home, history, meetings, dictionary, styles
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .home: return "Home"
            case .history: return "History"
            case .meetings: return "Meetings"
            case .dictionary: return "Dictionary"
            case .styles: return "Styles"
            }
        }
    }

    @Published var section: Section = .home
    @Published var refresh = 0
    @Published var importReport = ""
    @Published var from = ""
    @Published var to = ""
    @Published var entries: [PersonalDictionary.Entry] = AppSettings.dictionary.entries
    @Published var historyQuery = ""
    /// The Styles row whose example is shown.
    @Published var styleExample: AppCategory = .messages
    @Published var advancedOpen = false
    @Published var confirmClearHistory = false
    /// The History row under the pointer (its Copy button shows).
    @Published var hoveredHistory: UUID?
    // Meetings tab
    @Published var meetingQuery = ""
    /// The meeting open in the detail view (its folder name); nil = the list.
    @Published var openMeeting: String?
    @Published var meetingTitleDraft = ""
    @Published var meetingFind = ""
    @Published var meetingFindIndex = 0
    @Published var confirmDeleteMeeting = false
}

/// The main window's toolbar: the four tabs in the middle, Settings on the right.
final class MainToolbar: NSObject, NSToolbarDelegate {
    private static let tabs = NSToolbarItem.Identifier("tabs")
    private static let settings = NSToolbarItem.Identifier("settings")

    private let model: MainModel
    private let onSettings: () -> Void
    private let segments: NSSegmentedControl

    init(model: MainModel, onSettings: @escaping () -> Void) {
        self.model = model
        self.onSettings = onSettings
        segments = NSSegmentedControl(labels: MainModel.Section.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        segments.target = self
        segments.action = #selector(pick)
        segments.setAccessibilityLabel("Sections")
        segments.selectedSegmentBezelColor = Mist.accentNS
        sync()
    }

    func attach(to window: NSWindow) {
        let toolbar = NSToolbar(identifier: "VoiceTypeMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.tabs]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
    }

    /// Shows the model's tab as selected (after the tab was changed from code).
    func sync() { segments.selectedSegment = model.section.rawValue }

    @objc private func pick() {
        if let s = MainModel.Section(rawValue: segments.selectedSegment) { model.section = s }
    }

    @objc private func openSettings() { onSettings() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabs, .flexibleSpace, Self.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.tabs:
            item.label = "Sections"
            item.view = segments
        case Self.settings:
            item.label = "Settings"
            item.toolTip = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.isBordered = true
            item.target = self
            item.action = #selector(openSettings)
        default:
            return nil
        }
        return item
    }
}

struct MainView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.section {
                case .home: HomeView(app: app, model: model, history: app.history)
                case .history: HistoryView(model: model, history: app.history)
                case .meetings: MeetingsView(app: app, model: model, store: app.meetingStore, meetings: app.meetings)
                case .dictionary: DictionaryView(model: model)
                case .styles: StylesView(app: app, model: model)
                }
            }
            // Cap the readable width and centre it, so full screen doesn't stretch rows and tiles edge to edge.
            .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            Divider()
            StatusFooter(app: app, model: model).background(Mist.bar)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Mist.window)
        .tint(Mist.accent)
    }
}

/// The "Mist" palette: lavender-gray in light mode, charcoal-violet in dark.
enum Mist {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }
    static let accentNS = pair(0x6E5DB8, 0xB4A6F0)
    static let accent = Color(nsColor: accentNS)
    static let window = Color(nsColor: pair(0xF6F5FA, 0x1C1A23))
    static let bar = Color(nsColor: pair(0xEEECF4, 0x221F2B))
    static let card = Color(nsColor: pair(0xFFFFFF, 0x24212E))
    static let tile = Color(nsColor: pair(0xF1EEFA, 0x2C2839))
    static let border = Color(nsColor: pair(0xDEDBE7, 0x353042))
}

/// The Home tab: status, this week's numbers, your last few dictations, and all-time bests.
private struct HomeView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @ObservedObject var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusCard(app: app, model: model)
                Dashboard(history: history)
                if !history.items.isEmpty {
                    HStack {
                        Text("Recent").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("See all") { app.showMainWindow(.history) }.buttonStyle(.link)
                    }
                    VStack(spacing: 0) {
                        ForEach(history.items.prefix(3)) { item in
                            HistoryRow(item: item, hovering: model.hoveredHistory == item.id,
                                       onHover: { inside in
                                           if inside { model.hoveredHistory = item.id } else if model.hoveredHistory == item.id { model.hoveredHistory = nil }
                                       },
                                       onDelete: { history.delete(item) })
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Mist.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Mist.border))
                    bests
                }
            }
            .padding(24)
        }
    }

    private var bests: some View {
        let b = UsageStats.bests(history.items.map { .init(date: $0.date, text: $0.text, audioMillis: $0.audioMillis) })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Personal bests").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                StatTile(label: b.bestDay.map { "Best day · \($0.day.formatted(.dateTime.day().month(.abbreviated)))" } ?? "Best day",
                         value: "\((b.bestDay?.words ?? 0).formatted()) words")
                StatTile(label: "Longest dictation", value: "\(b.longestWords.formatted()) words")
                StatTile(label: "Fastest pace", value: b.fastestWPM > 0 ? "\(b.fastestWPM) wpm" : "—")
            }
        }
    }
}

/// Ready / paused / what needs fixing, with the one action that goes with it.
private struct StatusCard: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel

    var body: some View {
        let _ = model.refresh
        let problem = app.setupProblem
        HStack(spacing: 14) {
            Circle().fill(problem != nil ? Color.orange : (app.isPaused ? Color.secondary : Mist.accent))
                .frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem ?? (app.isPaused ? "Paused" : "Ready")).font(.system(size: 15, weight: .semibold))
                Text(problem != nil ? "Fix this so VoiceType can type for you."
                     : app.isPaused ? "\(triggerName) is off for up to an hour. \(SpeechModelInfo.name(app)) is loaded."
                     : "Hold \(triggerName) anywhere and start talking. \(SpeechModelInfo.name(app)), runs only on this Mac.")
                    .font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if problem != nil {
                Button("Fix") { app.showOnboarding() }
            } else {
                Button(app.isPaused ? "Resume" : "Pause for 1 hour") { app.togglePause(); model.refresh += 1 }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Mist.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Mist.border))
        .accessibilityElement(children: .contain)
    }
}

/// The Home tab's weekly section: last-7-days numbers, words per day, and where you dictate most.
/// Shows nothing before the first dictation.
private struct Dashboard: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        let entries = history.items.map { UsageStats.Entry(date: $0.date, text: $0.text, audioMillis: $0.audioMillis, app: $0.app) }
        let s = UsageStats.lastSevenDays(entries)
        if s.words > 0 {
            let streak = UsageStats.streak(entries)
            let apps = UsageStats.topApps(entries)
            let perDay = UsageStats.wordsPerDay(entries)
            let maxWords = perDay.map(\.words).max() ?? 0
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    StatTile(label: "Words · 7 days", value: s.words.formatted())
                    // wpm needs dictations with a known length; older history has none.
                    StatTile(label: "Speaking pace", value: s.wordsPerMinute > 0 ? "\(s.wordsPerMinute) wpm" : "—")
                    StatTile(label: "Saved vs typing", value: "\(s.minutesSaved) min")
                    StatTile(label: "Streak", value: "\(streak) day\(streak == 1 ? "" : "s")")
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Words per day").font(.system(size: 12)).foregroundColor(.secondary)
                        Chart(perDay, id: \.day) { d in
                            let isToday = d.day == perDay.last?.day
                            // Named days (not a date axis), so each label sits centred under its bar.
                            BarMark(x: .value("Day", isToday ? "Today" : d.day.formatted(.dateTime.weekday(.abbreviated))),
                                    y: .value("Words", d.words), width: .fixed(28))
                                .foregroundStyle(Mist.accent.opacity(isToday ? 1 : 0.5))
                                .cornerRadius(4)
                                .annotation(position: .top, spacing: 4) {
                                    if d.words > 0 {
                                        Text(d.words.formatted(.number.notation(.compactName)))
                                            .font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                                    }
                                }
                        }
                        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 11)) } }
                        .chartYAxis(.hidden)
                        // Headroom so the tallest bar's number isn't clipped.
                        .chartYScale(domain: 0...max(1, maxWords + maxWords / 4))
                        .frame(height: 100)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Mist.tile))
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top apps").font(.system(size: 12)).foregroundColor(.secondary)
                            ForEach(apps, id: \.app) { a in
                                HStack {
                                    Text(a.app).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(a.percent)%").font(.system(size: 13).monospacedDigit()).foregroundColor(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(14)
                        .frame(width: 200, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Mist.tile))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 6) {
                Text("Nothing this week yet").font(.system(size: 15, weight: .semibold))
                Text("Your words, pace and streak for the week show up here once you dictate.")
                    .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One number on the Home dashboard.
private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Mist.tile))
        .accessibilityElement(children: .combine)
    }
}

/// The speech model in use, for the footer and Settings.
enum SpeechModelInfo {
    static func slot(_ app: AppDelegate) -> ModelSlot {
        AppSettings.engineSpec(app.models).kind == .fastEnglish ? .moonshine : .whisper
    }

    static func name(_ app: AppDelegate) -> String {
        let spec = AppSettings.engineSpec(app.models)
        guard spec.kind == .hindiEnglish else { return "Moonshine Base" }
        if let cpp = Recognizers.whisperCppModel(spec, modelsRoot: app.models.root) {
            // "large-v3-turbo-q5_0" -> "large-v3-turbo": the quantisation suffix is noise here.
            return "Whisper " + ModelLayout.whisperCppName(cpp).replacingOccurrences(of: "-q[0-9]+_[0-9a-z]+$", with: "", options: .regularExpression)
        }
        let isTurbo = app.models.files(.whisper).contains { $0.lastPathComponent.hasPrefix("turbo") }
        return isTurbo ? "Whisper turbo" : "Whisper small"
    }
}

/// One quiet line at the bottom of the window: what's running, or the one thing that needs fixing.
private struct StatusFooter: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel

    var body: some View {
        let _ = model.refresh
        let problem = app.setupProblem
        HStack(spacing: 8) {
            Circle().fill(problem == nil ? Mist.accent : Color.orange).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(problem ?? "\(app.isPaused ? "Paused" : "Ready") · \(SpeechModelInfo.name(app)) · runs only on this Mac")
                .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if problem != nil { Button("Fix") { app.showOnboarding() }.controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh += 1 }
    }
}

// MARK: - Shared bits

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private var triggerName: String {
    switch TriggerKey.current {
    case .fn: return "fn"
    case .rightOption: return "right ⌥"
    case .optionSpace: return "⌥ Space"
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var model: MainModel
    @ObservedObject var history: HistoryStore

    private struct Day: Identifiable {
        let id: Date
        var items: [HistoryStore.Item]

        var title: String {
            let cal = Calendar.current
            if cal.isDateInToday(id) { return "Today" }
            if cal.isDateInYesterday(id) { return "Yesterday" }
            return id.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    /// Newest first, grouped by calendar day.
    private func days(_ items: [HistoryStore.Item]) -> [Day] {
        var out: [Day] = []
        for item in items {
            let day = Calendar.current.startOfDay(for: item.date)
            if out.last?.id == day { out[out.count - 1].items.append(item) } else { out.append(Day(id: day, items: [item])) }
        }
        return out
    }


    var body: some View {
        let q = model.historyQuery.lowercased()
        let items = q.isEmpty ? history.items : history.items.filter { $0.text.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary).accessibilityHidden(true)
                TextField("Search what you said", text: $model.historyQuery).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Mist.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Mist.border))
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)

            if items.isEmpty {
                VStack(spacing: 6) {
                    Text(history.items.isEmpty ? "Nothing yet" : "No matches").font(.system(size: 15, weight: .semibold))
                    if history.items.isEmpty {
                        Text("Hold \(triggerName) anywhere and start talking. Double-tap it\(KeyMonitor.handsFreeShortcutOn ? " (or press ⇧⌥ Space)" : "") for hands-free; esc cancels.")
                            .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days(items)) { day in
                            Text(day.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(day.items) { item in
                                HistoryRow(item: item, hovering: model.hoveredHistory == item.id,
                                           onHover: { inside in
                                               if inside { model.hoveredHistory = item.id } else if model.hoveredHistory == item.id { model.hoveredHistory = nil }
                                           },
                                           onDelete: { history.delete(item) })
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryStore.Item
    let hovering: Bool
    let onHover: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(item.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty { Text(meta).font(.system(size: 12)).foregroundColor(.secondary) }
            }
            Spacer(minLength: 0)
            // Always laid out, so rows don't jump when the pointer moves over them.
            Button("Copy") { copy(item.text) }.controlSize(.small).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Mist.tile : Color.clear))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .contextMenu {
            Button("Copy") { copy(item.text) }
            if item.raw != item.text { Button("Copy what was heard") { copy(item.raw) } }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// "Slack · Casual · hands-free 0:42"
    private var meta: String {
        var parts: [String] = []
        if let app = item.app { parts.append(app) }
        if let style = item.style { parts.append(style) }
        if item.handsFree == true, let ms = item.audioMillis { parts.append(String(format: "hands-free %d:%02d", ms / 60000, ms / 1000 % 60)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Dictionary

private struct DictionaryView: View {
    @ObservedObject var model: MainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Names and words VoiceType should always spell your way. Applied last, even after AI polish.")
                .font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("When I say (e.g. acme)", text: $model.from).textFieldStyle(.roundedBorder)
                TextField("Write (e.g. Acme)", text: $model.to).textFieldStyle(.roundedBorder)
                Button("Add") {
                    guard !model.from.isEmpty, !model.to.isEmpty else { return }
                    save(AppSettings.dictionary.plus(.init(model.from, model.to)))
                    model.from = ""; model.to = ""
                }
                .keyboardShortcut(.defaultAction)
            }
            if model.entries.isEmpty {
                Text("No words yet.").font(.system(size: 13)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(model.entries, id: \.self) { e in
                        HStack {
                            Text(e.from)
                            Image(systemName: "arrow.right").foregroundColor(.secondary).accessibilityHidden(true)
                            Text(e.to).bold()
                            Spacer()
                            Button(role: .destructive) { save(AppSettings.dictionary.minus(e.from)) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("Delete \(e.from)")
                        }
                    }
                }
                .listStyle(.inset)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Mist.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private func save(_ d: PersonalDictionary) { AppSettings.dictionary = d; model.entries = d.entries }
}

// MARK: - Styles

private struct StyleExample {
    let said: String
    let typed: String

    private static let casualSaid = "um so yeah i’ll be there at like 5 no wait 6"

    static func of(_ choice: StyleChoice) -> StyleExample {
        switch choice {
        case .casual:
            return .init(said: casualSaid, typed: "So yeah, I’ll be there at 6.")
        case .formal:
            return .init(said: "hey priya thanks for this i looked at it uh two comments on pricing can we close by friday",
                         typed: "Hi Priya, thanks for this. I’ve left two comments on the pricing section. Could we close it by Friday?")
        case .notes:
            return .init(said: "ship the android build then import turbo on the mac and test hands free in slack",
                         typed: "- Ship the Android build\n- Import Whisper turbo on the Mac\n- Test hands-free mode in Slack")
        case .off:
            // Run through the real instant rules, so this is exactly what would be typed.
            let said = "um so i think uh we should meet at 5 no wait 6"
            return .init(said: said, typed: RuleCleaner().clean(said))
        }
    }
}

private struct StylesView: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @AppStorage(Key.polish) var polish = true
    @AppStorage(Key.style(.messages)) var messages = StyleChoice.casual.rawValue
    @AppStorage(Key.style(.email)) var email = StyleChoice.formal.rawValue
    @AppStorage(Key.style(.notes)) var notes = StyleChoice.notes.rawValue
    @AppStorage(Key.style(.other)) var other = StyleChoice.off.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI polish").font(.system(size: 15, weight: .semibold))
                        Text("Tidies your words to suit the app you are typing in. Runs on Apple’s on-device model.")
                            .font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("AI polish", isOn: $polish).toggleStyle(.switch).labelsHidden()
                }
                if !app.polisher.isReady {
                    Label(app.polisher.statusText, systemImage: "info.circle").font(.system(size: 13)).foregroundColor(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(AppCategory.allCases, id: \.self) { c in
                        if c != AppCategory.allCases.first { Divider() }
                        row(c)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Mist.border))
                .disabled(!polish)
                .opacity(polish ? 1 : 0.5)
                example
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
    }

    private func stored(_ c: AppCategory) -> Binding<String> {
        switch c {
        case .messages: return $messages
        case .email: return $email
        case .notes: return $notes
        case .other: return $other
        }
    }

    private func row(_ c: AppCategory) -> some View {
        let base = stored(c)
        // Changing a row's style also shows that row's example.
        let choice = Binding<String>(get: { base.wrappedValue }, set: { base.wrappedValue = $0; model.styleExample = c })
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 13, weight: .semibold))
                Text(c.examples).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Picker(c.title, selection: choice) {
                ForEach(StyleChoice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(model.styleExample == c ? Mist.tile : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.styleExample = c }
    }

    private var example: some View {
        let c = model.styleExample
        let choice = polish ? (StyleChoice(rawValue: stored(c).wrappedValue) ?? .off) : .off
        let ex = StyleExample.of(choice)
        return HStack(alignment: .top, spacing: 12) {
            exampleCard("You say", ex.said, strong: false)
            exampleCard("\(c.title) · \(choice == .off ? "rules only" : choice.title) types", ex.typed, strong: true)
        }
    }

    private func exampleCard(_ title: String, _ text: String, strong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text(text).font(.system(size: 13, weight: strong ? .medium : .regular))
                .foregroundColor(strong ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Mist.tile))
    }
}

// MARK: - Settings (its own window)

struct SettingsPane: View {
    let app: AppDelegate
    @ObservedObject var model: MainModel
    @ObservedObject var history: HistoryStore
    @AppStorage(Key.trigger) var trigger = TriggerKey.fn.rawValue
    @AppStorage(Key.handsFreeShortcut) var handsFreeShortcut = true
    @AppStorage(Key.sounds) var sounds = true
    @AppStorage(Key.language) var language = "en"
    @AppStorage(Key.englishEngine) var engine = EngineKind.hindiEnglish.rawValue
    @AppStorage(Key.script) var script = "latin"
    @AppStorage(Key.translate) var translate = false
    @AppStorage(Key.fillers) var fillers = true
    @AppStorage(Key.corrections) var corrections = true
    @AppStorage(Key.commands) var commands = true
    @AppStorage(Key.capitalize) var capitalize = true
    @AppStorage(Key.finalPunct) var finalPunct = true
    @AppStorage(Key.flowBarIdle) var flowBarIdle = false
    @AppStorage(Key.history) var historyOn = true
    @AppStorage(Key.keepRecordings) var keepRecordings = false
    @AppStorage(Key.meetingShortcut) var meetingShortcut = true
    @AppStorage(Key.meetingMaxMinutes) var meetingMaxMinutes = MeetingLimit.defaultMinutes
    @AppStorage(Key.meetingKeepAudio) var meetingKeepAudio = false
    @AppStorage(Key.meetingHideFromCapture) var meetingHideFromCapture = true
    @AppStorage(Key.meetingEchoFilter) var meetingEchoFilter = true

    private struct Issue: Identifiable {
        let id: String
        let button: String
        let action: () -> Void
    }

    /// Only what still needs doing; an empty list collapses to one "all set" row.
    private var issues: [Issue] {
        var out: [Issue] = []
        // Each asks macOS first (which lists VoiceType in System Settings), then opens the pane on later presses.
        func ask(_ kind: Permissions.Kind, _ title: String) {
            guard !Permissions.isGranted(kind) else { return }
            out.append(Issue(id: title, button: Permissions.buttonTitle(kind)) {
                Permissions.request(kind) {
                    if kind == .inputMonitoring { app.applyTrigger() }
                    model.refresh += 1
                }
            })
        }
        ask(.microphone, "Microphone")
        ask(.accessibility, "Accessibility (auto-paste)")
        if trigger != TriggerKey.optionSpace.rawValue { ask(.inputMonitoring, "Input Monitoring (\(TriggerKey.current.title) key)") }
        if trigger == TriggerKey.fn.rawValue, FnKeySetting.isDoNothing == false {
            out.append(Issue(id: "Set “Press fn key to” to Do Nothing", button: "Open Keyboard Settings") {
                FnKeySetting.openKeyboardSettings()
            })
        }
        return out
    }

    var body: some View {
        let _ = model.refresh
        let issues = self.issues
        let slot = SpeechModelInfo.slot(app)
        let modelReady = app.models.isReady(slot)
        Form {
            Section("Dictation") {
                Picker("Dictation key", selection: $trigger) {
                    ForEach(TriggerKey.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(isOn: $handsFreeShortcut) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hands-free shortcut: ⇧⌥ Space")
                        Text("Press once to start, again to finish. Works alongside double-tapping the dictation key.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $sounds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play sounds")
                        Text("A soft purr when VoiceType starts listening, and a pop when it stops.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                LabeledContent("Language") {
                    Picker("Language", selection: $language) {
                        Text("English").tag("en"); Text("हिंदी").tag("hi"); Text("Both").tag("auto")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if language != "en" {
                    Toggle(isOn: $translate) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Translate to English")
                            Text("Hindi and Hinglish are typed as plain English. English stays as it is.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if language != "en" && !translate {
                    LabeledContent("Hindi is written in") {
                        Picker("Hindi is written in", selection: $script) {
                            Text("Latin").tag("latin"); Text("देवनागरी").tag("devanagari")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            }
            Section("Setup") {
                if issues.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).accessibilityHidden(true)
                        Text("Permissions are all set")
                        Spacer()
                        Button("Run setup again") { app.showOnboarding() }
                    }
                } else {
                    ForEach(issues) { issue in
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange).accessibilityHidden(true)
                            Text(issue.id)
                            Spacer()
                            Button(issue.button, action: issue.action)
                        }
                    }
                    if [Permissions.Kind.microphone, .accessibility, .inputMonitoring].contains(where: { Permissions.hasAsked($0) && !Permissions.isGranted($0) }) {
                        Text("VoiceType is already in those lists in System Settings. Switch it on there; you don’t need to add it.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button("Run setup again") { app.showOnboarding() }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech model")
                        Text(modelReady ? "\(SpeechModelInfo.name(app)) · \(ByteCountFormatter.string(fromByteCount: app.models.size(slot), countStyle: .file))" : "Not imported")
                            .font(.caption).foregroundColor(modelReady ? .secondary : .orange)
                    }
                    Spacer()
                    Menu(modelReady ? "Change…" : "Add…") {
                        Button("Download speech model (\(KnownModels.recommended.sizeText))") { app.downloadModel() }
                        Button("Import model…") { app.importModels { model.importReport = $0; model.refresh += 1 } }
                    }
                    .fixedSize()
                }
                if !model.importReport.isEmpty { Text(model.importReport).font(.caption).textSelection(.enabled) }
            }
            meetingsSection
            Section {
                Toggle("Save history on this Mac", isOn: $historyOn)
                HStack {
                    Text("Saved dictations")
                    Spacer()
                    Button("Clear history…", role: .destructive) { model.confirmClearHistory = true }
                        .disabled(history.items.isEmpty)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("VoiceType has no network access. macOS enforces this, not the app.")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
            }
            Section {
                Button { model.advancedOpen.toggle() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Advanced")
                            Text("Clean-up rules, flow bar when idle, recordings, performance log")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                            .rotationEffect(.degrees(model.advancedOpen ? 90 : 0)).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(model.advancedOpen ? "expanded" : "collapsed")
            }
            if model.advancedOpen { advanced }
            Section {
                HStack {
                    Text("VoiceType \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Open-source licences") { app.showLicenses() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
        .confirmationDialog("Delete all saved dictations?", isPresented: $model.confirmClearHistory) {
            Button("Delete all", role: .destructive) { history.clearAll() }
        } message: {
            Text("This can’t be undone.")
        }
        .onChange(of: trigger) { _ in app.applyTrigger(); model.refresh += 1 }
        .onChange(of: handsFreeShortcut) { _ in app.applyTrigger() }
        .onChange(of: meetingShortcut) { app.applyTrigger() }
        .onChange(of: meetingHideFromCapture) { app.applyCaptureHiding() }
        .onChange(of: language) { _ in app.dictation.warmUp(); model.refresh += 1 }
        .onChange(of: translate) { _ in app.dictation.warmUp() }
        .onChange(of: engine) { _ in model.refresh += 1 }
        .onChange(of: flowBarIdle) { _ in app.flowBar.refreshIdleVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh += 1 }
    }

    private var meetingsSection: some View {
        Section {
            Toggle(isOn: $meetingShortcut) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting shortcut: \(KeyMonitor.meetingShortcutTitle)")
                    Text("Starts and stops a meeting recording from any app. Also in the menu bar and the Meetings tab.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Picker("Maximum length", selection: $meetingMaxMinutes) {
                ForEach(MeetingLimit.choices, id: \.self) { Text(MeetingLimit.title($0)).tag($0) }
            }
            Toggle(isOn: $meetingEchoFilter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove echo when not using headphones")
                    Text("Without headphones your mic also hears the others. Drops those repeated lines from Me.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Toggle(isOn: $meetingHideFromCapture) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide from screen sharing while recording")
                    Text("Asks macOS to leave the flow bar and VoiceType’s windows out of screen shares and recordings. Check with your meeting app: not every capture method honours it.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Toggle(isOn: $meetingKeepAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep audio after transcription")
                    Text("Off: mic.wav and system.wav are deleted once the transcript is saved (about 115 MB an hour each).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System audio (the other people)")
                    Text(SystemAudioPermission.statusText).font(.caption)
                        .foregroundColor(SystemAudioPermission.lastState == .ok ? .secondary : .orange)
                }
                Spacer()
                Button("Turn on…") { SystemAudioPermission.openSettings() }
            }
            HStack {
                Text("Meetings folder")
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.meetingStore.root]) }
            }
        } header: {
            Text("Meetings")
        } footer: {
            Text("Your mic is “Me”, the sound of other apps is “Others”. Both are transcribed on this Mac while you talk.")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
        }
    }

    @ViewBuilder private var advanced: some View {
        Section("Clean-up rules (instant)") {
            Toggle("Remove filler words (um, uh, like, you know, matlab, haan toh)", isOn: $fillers)
            Toggle("Apply self-corrections (“5 no wait 6”, “I mean”, “nahi nahi”)", isOn: $corrections)
            Toggle("Spoken commands (new line, new paragraph, comma, full stop, question mark)", isOn: $commands)
            Toggle("Auto-capitalise", isOn: $capitalize)
            Toggle("Add final punctuation", isOn: $finalPunct)
        }
        Section("Flow bar and engine") {
            Toggle("Show the flow bar when idle", isOn: $flowBarIdle)
            Picker("English engine", selection: $engine) {
                Text("Whisper (best accuracy, uses your Dictionary)").tag(EngineKind.hindiEnglish.rawValue)
                Text("Fast English (Moonshine, needs its own model)").tag(EngineKind.fastEnglish.rawValue)
            }
            .disabled(language != "en")
            ForEach(ModelSlot.allCases, id: \.self) { slot in
                HStack {
                    Image(systemName: app.models.isReady(slot) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(app.models.isReady(slot) ? .green : .secondary).accessibilityHidden(true)
                    Text(slot.title)
                    Spacer()
                    Text(slot == .vad && app.models.isVADBuiltIn ? "built in" :
                            (app.models.isReady(slot) ? ByteCountFormatter.string(fromByteCount: app.models.size(slot), countStyle: .file) : "missing"))
                        .foregroundColor(.secondary)
                }
            }
        }
        Section("Debug") {
            Toggle("Keep recordings", isOn: $keepRecordings)
            Text("Loaded: \(app.speech.loadedName ?? "none")\(app.speech.lastLanguage.map { " · last decode: \($0.isEmpty ? "auto" : $0)" } ?? "") · \(EngineSpec(kind: .fastEnglish, language: "en").threads) threads · AI polish: \(app.polisher.statusText)")
                .font(.caption)
            ForEach(PerfLog.shared.recent.prefix(8)) { e in
                Text("\(e.date.formatted(date: .omitted, time: .standard))  \(e.engine)  audio \(e.audioMillis) ms  decode \(e.decodeMillis) ms  RTF \(String(format: "%.3f", e.rtf))\(e.polishMillis >= 0 ? "  polish \(e.polishMillis) ms" : "")\(e.polishNote.map { "  [\($0)]" } ?? "")")
                    .font(.system(.caption, design: .monospaced))
            }
            Button("Refresh performance log") { model.refresh += 1 }
        }
    }
}

func openPrivacy(_ anchor: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
}
