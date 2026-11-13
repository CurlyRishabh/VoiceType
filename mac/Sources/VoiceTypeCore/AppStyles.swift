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

/// Numbers for the Home screen, computed from local history only.
public struct UsageStats: Equatable, Sendable {
    public let words: Int
    public let speakingMinutes: Double
    public var wordsPerMinute: Int { speakingMinutes < 0.05 ? 0 : Int((Double(words) / speakingMinutes).rounded()) }
    /// Typing the same words at 45 wpm, minus the time spent speaking.
    public var minutesSaved: Int { max(0, Int((Double(words) / 45.0 - speakingMinutes).rounded())) }

    public struct Entry: Sendable {
        public let date: Date
        public let text: String
        public let audioMillis: Int?
        public init(date: Date, text: String, audioMillis: Int?) { self.date = date; self.text = text; self.audioMillis = audioMillis }
    }

    public static func lastSevenDays(_ entries: [Entry], now: Date = Date()) -> UsageStats {
        let since = now.addingTimeInterval(-7 * 24 * 3600)
        let recent = entries.filter { $0.date >= since && $0.date <= now }
        let words = recent.reduce(0) { $0 + wordCount($1.text) }
        let minutes = recent.reduce(0.0) { $0 + Double($1.audioMillis ?? 0) / 60_000 }
        return UsageStats(words: words, speakingMinutes: minutes)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}
