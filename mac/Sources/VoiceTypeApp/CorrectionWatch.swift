import AppKit
import ApplicationServices
import Foundation
import VoiceTypeCore

/// After a dictation is pasted, keeps an eye on that one text field (through Accessibility, on a
/// background queue, nothing stored) and judges your edits ONCE: when you move to another field or
/// app, when the next dictation starts, or after two minutes. Judging once means a word half
/// retyped during a pause ("Rish…") is never learned. Respelled words become Dictionary entries
/// (CorrectionLearner); grammar, sentence capitals and word swaps don't.
final class CorrectionWatch {
    private let queue = DispatchQueue(label: "correction-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    // `queue` only.
    private var field: Inserter.Field?
    private var typed = ""
    private var known = PersonalDictionary.empty
    private var started: TimeInterval = 0
    private var lastValue: String?
    private var onLearn: (([PersonalDictionary.Entry]) -> Void)?

    static let interval = 2.0
    static let window = 120.0

    /// Starts watching `field` (ending any earlier watch, which is judged first).
    func watch(_ field: Inserter.Field, typed: String, onLearn: @escaping ([PersonalDictionary.Entry]) -> Void) {
        let known = AppSettings.dictionary
        queue.async {
            self.judgeAndStop()
            self.field = field
            self.typed = typed
            self.known = known
            self.onLearn = onLearn
            self.started = ProcessInfo.processInfo.systemUptime
            self.lastValue = nil
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
        }
    }

    /// A new dictation: what was edited so far is judged now, then the watch ends.
    func finish() { queue.async { self.judgeAndStop() } }

    private func poll() {
        guard let field else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard elapsed < Self.window, Inserter.isFocused(field.element) else { return judgeAndStop() }
        guard let v = Inserter.value(of: field.element), v.utf16.count <= Inserter.maxWatchedCharacters else { return judgeAndStop() }
        lastValue = v
    }

    private func judgeAndStop() {
        timer?.cancel()
        timer = nil
        defer { field = nil; onLearn = nil; lastValue = nil }
        guard let field, let value = lastValue, value != field.before + typed + field.after else { return }
        guard let report = onLearn else { return }
        let (typed, known) = (self.typed, self.known)
        // On the main thread: NSSpellChecker isn't safe to use from other threads (the text is small).
        DispatchQueue.main.async {
            let learned = CorrectionLearner.corrections(typed: typed, before: field.before, after: field.after, now: value,
                                                        known: known, isWord: Self.isWord)
            if !learned.isEmpty { report(learned) }
        }
    }

    /// Ordinary vocabulary in any language the system spell checker knows.
    static func isWord(_ w: String) -> Bool {
        guard w.count > 1 else { return true }
        let checker = NSSpellChecker.shared
        let miss = checker.checkSpelling(of: w, startingAt: 0, language: nil, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }
}
