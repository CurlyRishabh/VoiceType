import Foundation
import Testing
@testable import VoiceTypeCore

struct GestureTests {
    typealias E = TriggerGesture.Effect

    /// Feeds events in order and returns all effects, sending ticks at deadlines like the app does.
    func run(_ events: [TriggerGesture.Event], into g: inout TriggerGesture) -> [E] {
        events.flatMap { g.handle($0) }
    }

    @Test func holdIsPushToTalk() {
        var g = TriggerGesture()
        #expect(g.handle(.keyDown(0)) == [.begin])
        #expect(g.handle(.tick(0.3)) == [.becameHold])
        #expect(g.handle(.keyUp(4.2)) == [.finish])
        #expect(g.state == .idle)
    }

    @Test func longPressWithoutTickStillFinishes() {
        var g = TriggerGesture()
        #expect(run([.keyDown(0), .keyUp(2.0)], into: &g) == [.begin, .finish])
    }

    @Test func pausesDoNotStopAHold() {
        var g = TriggerGesture()
        _ = run([.keyDown(0), .tick(0.3)], into: &g)
        #expect(g.handle(.tick(9)) == [])
        #expect(g.state == .holding)
    }

    @Test func singleTapIsDiscarded() {
        var g = TriggerGesture()
        #expect(run([.keyDown(0), .keyUp(0.1)], into: &g) == [.begin])
        #expect(abs((g.nextDeadline ?? 0) - 0.45) < 1e-9)
        #expect(g.handle(.tick(0.2)) == [])
        #expect(g.handle(.tick(0.46)) == [.cancel])
        #expect(g.state == .idle)
    }

    @Test func doubleTapIsHandsFreeAndNextPressFinishes() {
        var g = TriggerGesture()
        #expect(run([.keyDown(0), .keyUp(0.1), .keyDown(0.3)], into: &g) == [.begin, .becameHandsFree])
        #expect(g.handle(.keyUp(0.4)) == [])
        #expect(g.handle(.tick(60)) == [])          // long pause: still listening
        #expect(g.handle(.otherKey) == [])          // typing while dictating is allowed
        #expect(g.handle(.keyDown(95)) == [.finish])
        #expect(g.handle(.keyUp(95.1)) == [])       // the release after finishing is ignored
        #expect(g.state == .idle)
    }

    @Test func slowSecondTapStartsAFreshPress() {
        var g = TriggerGesture()
        _ = run([.keyDown(0), .keyUp(0.1)], into: &g)
        #expect(g.handle(.keyDown(0.9)) == [.cancel, .begin])
        #expect(g.state == .pressed(since: 0.9))
    }

    @Test func fnPlusAnotherKeyIsANormalShortcut() {
        var g = TriggerGesture()
        #expect(run([.keyDown(0), .otherKey], into: &g) == [.begin, .cancel])
        var h = TriggerGesture()
        #expect(run([.keyDown(0), .tick(0.3), .otherKey], into: &h) == [.begin, .becameHold, .cancel])
    }

    @Test func typingRightAfterATapCancels() {
        var g = TriggerGesture()
        #expect(run([.keyDown(0), .keyUp(0.1), .otherKey], into: &g) == [.begin, .cancel])
    }

    @Test func escapeCancelsEverywhere() {
        var a = TriggerGesture(); _ = a.handle(.keyDown(0))
        #expect(a.handle(.escape) == [.cancel])
        var b = TriggerGesture(); _ = run([.keyDown(0), .tick(0.3)], into: &b)
        #expect(b.handle(.escape) == [.cancel])
        var c = TriggerGesture(); _ = run([.keyDown(0), .keyUp(0.1), .keyDown(0.2)], into: &c)
        #expect(c.handle(.escape) == [.cancel])
        var d = TriggerGesture()
        #expect(d.handle(.escape) == [])
    }

    @Test func flowBarButtons() {
        var g = TriggerGesture()
        _ = run([.keyDown(0), .keyUp(0.1), .keyDown(0.2)], into: &g)
        #expect(g.handle(.stopButton) == [.finish])
        var h = TriggerGesture()
        _ = run([.keyDown(0), .keyUp(0.1), .keyDown(0.2)], into: &h)
        #expect(h.handle(.cancelButton) == [.cancel])
    }

    @Test func startHandsFreeFromMenu() {
        var g = TriggerGesture()
        #expect(g.startHandsFree() == [.begin, .becameHandsFree])
        #expect(g.startHandsFree() == [])
        #expect(g.handle(.keyDown(5)) == [.finish])
    }

    @Test func keyRepeatIsIgnored() {
        var g = TriggerGesture()
        _ = g.handle(.keyDown(0))
        #expect(g.handle(.keyDown(0.05)) == [])
    }
}

struct AppStyleTests {
    @Test func categories() {
        #expect(AppStyleMap.category(bundleID: "com.tinyspeck.slackmacgap") == .messages)
        #expect(AppStyleMap.category(bundleID: "com.apple.mail") == .email)
        #expect(AppStyleMap.category(bundleID: "md.obsidian") == .notes)
        #expect(AppStyleMap.category(bundleID: "com.google.Chrome") == .other)
        #expect(AppStyleMap.category(bundleID: nil) == .other)
    }

    @Test func defaults() {
        #expect(AppStyleMap.defaultChoice(.messages) == .casual)
        #expect(AppStyleMap.defaultChoice(.email) == .formal)
        #expect(AppStyleMap.defaultChoice(.notes) == .notes)
        #expect(AppStyleMap.defaultChoice(.other) == .off)
        #expect(StyleChoice.formal.polishStyle == .professional)
        #expect(StyleChoice.off.polishStyle == nil)
    }

    @Test func stats() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = [
            UsageStats.Entry(date: now.addingTimeInterval(-60), text: "one two three four five six", audioMillis: 3000),
            UsageStats.Entry(date: now.addingTimeInterval(-3600), text: "- seven, eight!", audioMillis: 1000),
            UsageStats.Entry(date: now.addingTimeInterval(-8 * 24 * 3600), text: "old words not counted", audioMillis: 5000),
        ]
        let s = UsageStats.lastSevenDays(entries, now: now)
        #expect(s.words == 8)
        #expect(abs(s.speakingMinutes - 4.0 / 60) < 1e-9)
        #expect(s.wordsPerMinute == 120)
        #expect(UsageStats.wordCount("नमस्ते, मेरा नाम राहुल है") == 5)
        #expect(UsageStats(words: 900, speakingMinutes: 6).minutesSaved == 14)
    }
}
