import Foundation

/// Which kind of app the user is typing in, decided from the frontmost app's bundle identifier.
public enum AppCategory: String, CaseIterable, Sendable, Codable {
    case messages, email, notes, other

    public var title: String {
        switch self {
        case .messages: return "Messages"
        case .email: return "Email"
        case .notes: return "Notes and docs"
        case .other: return "Every other app"
        }
    }

    public var examples: String {
        switch self {
        case .messages: return "Messages, WhatsApp, Slack, Teams, Telegram, Discord"
        case .email: return "Mail, Outlook, Spark, Superhuman"
        case .notes: return "Notes, Obsidian, Notion, Pages, Word, Bear"
        case .other: return "Browsers, code editors and everything else"
        }
    }
}

/// What AI polish does in a category. `.off` = instant rules only.
public enum StyleChoice: String, CaseIterable, Sendable, Codable {
    case casual, formal, notes, off

    public var title: String {
        switch self {
        case .casual: return "Casual"
        case .formal: return "Formal"
        case .notes: return "Notes"
        case .off: return "Off"
        }
    }

    public var polishStyle: PolishStyle? {
        switch self {
        case .casual: return .casual
        case .formal: return .professional
        case .notes: return .notes
        case .off: return nil
        }
    }
}

public enum AppStyleMap {
    static let known: [String: AppCategory] = [
        // messages
        "com.apple.MobileSMS": .messages, "net.whatsapp.WhatsApp": .messages, "desktop.WhatsApp": .messages,
        "com.tinyspeck.slackmacgap": .messages, "com.microsoft.teams2": .messages, "com.microsoft.teams": .messages,
        "ru.keepcoder.Telegram": .messages, "org.telegram.desktop": .messages, "com.hnc.Discord": .messages,
        "org.whispersystems.signal-desktop": .messages, "com.facebook.archon": .messages,
        // email
        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email, "com.airmailapp.airmail2": .email, "it.bloop.airmail2": .email,
        // notes and documents
        "com.apple.Notes": .notes, "md.obsidian": .notes, "notion.id": .notes, "com.apple.iWork.Pages": .notes,
        "com.microsoft.Word": .notes, "com.apple.TextEdit": .notes, "net.shinyfrog.bear": .notes,
        "com.agiletortoise.Drafts-OSX": .notes, "com.lukilabs.lukiapp": .notes,
    ]

    public static func category(bundleID: String?) -> AppCategory {
        guard let bundleID else { return .other }
        return known[bundleID] ?? .other
    }

    public static func defaultChoice(_ c: AppCategory) -> StyleChoice {
        switch c {
        case .messages: return .casual
        case .email: return .formal
        case .notes: return .notes
        case .other: return .off
        }
    }
}

/// Numbers for the top of History, computed from local history only.
public struct UsageStats: Equatable, Sendable {
    public let words: Int
    public let speakingMinutes: Double
    /// Words from dictations whose length is known (history from before the redesign has none);
    /// speed and time saved use only these, so old entries can't inflate them.
    public let timedWords: Int

    public init(words: Int, speakingMinutes: Double, timedWords: Int? = nil) {
        self.words = words
        self.speakingMinutes = speakingMinutes
        self.timedWords = timedWords ?? words
    }

    public var wordsPerMinute: Int { speakingMinutes < 0.05 ? 0 : Int((Double(timedWords) / speakingMinutes).rounded()) }
    /// Typing the same words at 45 wpm, minus the time spent speaking.
    public var minutesSaved: Int { max(0, Int((Double(timedWords) / 45.0 - speakingMinutes).rounded())) }

    public struct Entry: Sendable {
        public let date: Date
        public let text: String
        public let audioMillis: Int?
        public let app: String?
        public init(date: Date, text: String, audioMillis: Int?, app: String? = nil) {
            self.date = date; self.text = text; self.audioMillis = audioMillis; self.app = app
        }
    }

    public struct DayWords: Equatable, Sendable { public let day: Date; public let words: Int }
    public struct AppShare: Equatable, Sendable { public let app: String; public let percent: Int }

    /// Words per calendar day for the 7 days ending today, oldest first; empty days are 0.
    public static func wordsPerDay(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [DayWords] {
        let today = calendar.startOfDay(for: now)
        var words: [Date: Int] = [:]
        for e in entries where e.date <= now { words[calendar.startOfDay(for: e.date), default: 0] += wordCount(e.text) }
        return (0..<7).reversed().map {
            let day = calendar.date(byAdding: .day, value: -$0, to: today)!
            return DayWords(day: day, words: words[day] ?? 0)
        }
    }

    public struct Bests: Equatable, Sendable {
        public let bestDay: DayWords?
        public let longestWords: Int
        public let fastestWPM: Int
    }

    /// All-time records. Pace only counts dictations of 10+ words and 3+ seconds, so a quick "yes" can't set it.
    public static func bests(_ entries: [Entry], calendar: Calendar = .current) -> Bests {
        var perDay: [Date: Int] = [:]
        var longest = 0, fastest = 0
        for e in entries {
            let words = wordCount(e.text)
            perDay[calendar.startOfDay(for: e.date), default: 0] += words
            longest = max(longest, words)
            if let ms = e.audioMillis, ms >= 3000, words >= 10 {
                fastest = max(fastest, Int((Double(words) / (Double(ms) / 60_000)).rounded()))
            }
        }
        let best = perDay.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
        return Bests(bestDay: best.map { DayWords(day: $0.key, words: $0.value) }, longestWords: longest, fastestWPM: fastest)
    }

    /// Days in a row with a dictation, ending today, or yesterday when today has none yet.
    public static func streak(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(entries.filter { $0.date <= now }.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while days.contains(day) { count += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        return count
    }

    /// The apps that got the most dictated words in the last 7 days, with their share of words, biggest first.
    public static func topApps(_ entries: [Entry], now: Date = Date(), limit: Int = 3) -> [AppShare] {
        let since = now.addingTimeInterval(-7 * 24 * 3600)
        var words: [String: Int] = [:]
        for e in entries where e.date >= since && e.date <= now {
            if let app = e.app, !app.isEmpty { words[app, default: 0] += wordCount(e.text) }
        }
        let total = words.values.reduce(0, +)
        guard total > 0 else { return [] }
        return words.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { AppShare(app: $0.key, percent: Int((Double($0.value) * 100 / Double(total)).rounded())) }
    }

    public static func lastSevenDays(_ entries: [Entry], now: Date = Date()) -> UsageStats {
        let since = now.addingTimeInterval(-7 * 24 * 3600)
        let recent = entries.filter { $0.date >= since && $0.date <= now }
        let words = recent.reduce(0) { $0 + wordCount($1.text) }
        let timed = recent.filter { ($0.audioMillis ?? 0) > 0 }
        let minutes = timed.reduce(0.0) { $0 + Double($1.audioMillis ?? 0) / 60_000 }
        return UsageStats(words: words, speakingMinutes: minutes, timedWords: timed.reduce(0) { $0 + wordCount($1.text) })
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}
