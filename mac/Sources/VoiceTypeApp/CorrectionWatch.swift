import AppKit
import ApplicationServices
import Foundation
import VoiceTypeCore

/// After a dictation is pasted, keeps an eye on that one text field (through Accessibility, on a
/// background queue, nothing stored) and judges your edits ONCE: when you move to another field or
/// app, send the text (a chat box empties), start the next dictation, or after two minutes.
/// Respelled words become Dictionary entries (CorrectionLearner); grammar, sentence capitals, word
/// swaps and half-typed words don't.
final class CorrectionWatch {
    private let queue = DispatchQueue(label: "correction-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    // `queue` only.
    private var field: Inserter.Field?
    /// The field's whole text before the paste; `field.before`/`after` are set from where the paste is
    /// found in it (`located`), not from the cursor.
    private var original = ""
    private var located = false
    /// The previous watch, for a second dictation into the same field.
    private var previous: (element: AXUIElement, before: String)?
    private var typed = ""
    private var known = PersonalDictionary.empty
    private var started: TimeInterval = 0
    private var lastValue: String?
    private var misses = 0
    private var onLearn: (([PersonalDictionary.Entry]) -> Void)?

    /// Often enough to see a fix made just before pressing Return in a chat box.
    static let interval = 0.15
    static let window = 120.0
    /// Reads in a row that don't answer (a busy app), or don't show the dictation yet (the paste
    /// hasn't landed), before giving up: about 2.4 s.
    static let maxMisses = 16

    /// Starts watching `field` after a dictation was pasted into it. An earlier watch is judged
    /// first. Another dictation into the same field keeps one window from the first dictation to
    /// the end of this one, so a fix in any of them is still seen.
    func watch(_ field: Inserter.Field, typed: String, onLearn: @escaping ([PersonalDictionary.Entry]) -> Void) {
        let known = AppSettings.dictionary
        queue.async {
            let previous = self.located ? self.field.map { ($0.element, $0.before) } : nil
            self.judgeAndStop("next dictation")
            self.previous = previous
            self.field = field
            self.original = field.before + field.after
            self.located = false
            self.typed = typed
            self.known = known
            self.onLearn = onLearn
            self.started = ProcessInfo.processInfo.systemUptime
            self.lastValue = nil
            self.misses = 0
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
        }
    }

    /// A dictation that isn't watched (no readable field): the last one is judged now.
    func finish() { queue.async { self.judgeAndStop("next dictation") } }

    private func poll() {
        guard var field else { return }
        guard ProcessInfo.processInfo.systemUptime - started < Self.window else { return judgeAndStop("time limit") }
        let seen = lastValue != nil
        switch Inserter.focus(of: field.element) {
        case .elsewhere: return seen ? judgeAndStop("focus left the field") : missed("focus elsewhere")
        case .unknown: return missed("no answer")
        case .moved(let other):
            // Same app, another element: a web chat box the page rebuilt is the same box while it still
            // holds the dictation (and before the paste is found, the paste went where the focus is).
            if located {
                guard let v = Inserter.value(of: other), CorrectionLearner.dictationStillThere(v, before: field.before, after: field.after) else {
                    return seen ? judgeAndStop("focus left the field") : missed("focus moved")
                }
            }
            field = Inserter.Field(element: other, before: field.before, after: field.after)
            self.field = field
        case .here: break
        }
        guard let v = Inserter.value(of: field.element) else { return missed("no text value") }
        guard v.utf16.count <= Inserter.maxWatchedCharacters else { return judgeAndStop("field too long") }
        if !located {
            guard let spot = CorrectionLearner.locate(typed, was: original, now: v) else { return missed("paste not found") }
            located = true
            field = Inserter.Field(element: field.element, before: spot.before, after: spot.after)
            typed = spot.middle
            // Another dictation into the same field: judged together from the first one's start.
            if let p = previous, CFEqual(p.element, field.element),
               let joined = CorrectionLearner.joinDictations(before: p.before, newBefore: spot.before, typed: spot.middle) {
                field = Inserter.Field(element: field.element, before: p.before, after: spot.after)
                typed = joined
            }
            previous = nil
            self.field = field
        }
        // Sent or cleared (a chat box after Return): judge the last edit seen while the dictation was there.
        guard CorrectionLearner.dictationStillThere(v, before: field.before, after: field.after) else {
            return seen ? judgeAndStop("text sent or cleared") : missed("dictation gone")
        }
        misses = 0
        lastValue = v
    }

    private func missed(_ why: String) {
        misses += 1
        if misses >= Self.maxMisses { judgeAndStop("field stopped answering (\(why))") }
    }

    private func judgeAndStop(_ why: String) {
        timer?.cancel()
        timer = nil
        defer { field = nil; onLearn = nil; lastValue = nil; located = false }
        guard let field else { return }
        guard let value = lastValue, value != field.before + typed + field.after else {
            return Diagnostics.log("corrections: \(why), \(lastValue == nil ? "nothing read" : "no edits")")
        }
        guard let report = onLearn else { return }
        let (typed, known) = (self.typed, self.known)
        // On the main thread: NSSpellChecker isn't safe to use from other threads (the text is small).
        DispatchQueue.main.async {
            let learned = CorrectionLearner.corrections(typed: typed, before: field.before, after: field.after, now: value,
                                                        known: known, isWord: Self.isWord)
            Diagnostics.log("corrections: \(why), edited, \(learned.count) learned")
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
