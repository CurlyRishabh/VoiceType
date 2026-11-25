import ApplicationServices
import Foundation
import VoiceTypeCore

/// After a dictation is pasted, reads the same text field every 2 s for up to a minute (only that
/// field, only through Accessibility, nothing is stored). Once you've edited it and stopped for a
/// few seconds, the words you respelled become Dictionary entries (CorrectionLearner). A new
/// dictation, or the field going away, ends the watch.
final class CorrectionWatch {
    private var timer: Timer?
    private var field: Inserter.Field?
    private var typed = ""
    private var started: TimeInterval = 0
    private var lastValue: String?
    private var stableSince: TimeInterval = 0
    private var onLearn: (([PersonalDictionary.Entry]) -> Void)?

    static let interval = 2.0
    static let window = 60.0
    /// The field must be unchanged this long after an edit before it is judged.
    static let settle = 4.0

    func watch(_ field: Inserter.Field, typed: String, onLearn: @escaping ([PersonalDictionary.Entry]) -> Void) {
        stop()
        self.field = field
        self.typed = typed
        self.onLearn = onLearn
        started = ProcessInfo.processInfo.systemUptime
        lastValue = field.before + typed + field.after
        stableSince = started
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        field = nil
        onLearn = nil
    }

    private func poll() {
        guard let field else { return stop() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - started < Self.window, let value = Inserter.value(of: field.element) else { return stop() }
        if value != lastValue {
            lastValue = value
            stableSince = now
            return
        }
        guard now - stableSince >= Self.settle, value != field.before + typed + field.after else { return }
        let learned = CorrectionLearner.corrections(typed: typed, before: field.before, after: field.after, now: value,
                                                    known: AppSettings.dictionary)
        guard !learned.isEmpty else { return } // keep watching: the fix may still be coming
        let report = onLearn
        stop()
        report?(learned)
    }
}
