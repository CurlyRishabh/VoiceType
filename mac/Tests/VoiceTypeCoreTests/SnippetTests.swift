import Foundation
import Testing
@testable import VoiceTypeCore

@Suite struct SnippetTests {
    let set = SnippetSet([
        .init("my LinkedIn", "https://www.linkedin.com/in/someone/"),
        .init("my email", "me@example.com"),
        .init("my work email", "me@work.example"),
        .init("insert date", "{date}"),
        .init("today's plan", "1. Standup\n2. Review"),
    ])
    let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18
    let locale = Locale(identifier: "en_GB")

    func run(_ s: String) -> String { set.apply(s, now: now, locale: locale).text }

    @Test func wholeDictationIsOnlyTheText() {
        #expect(run("My LinkedIn.") == "https://www.linkedin.com/in/someone/")
        #expect(run("my linked in") == "https://www.linkedin.com/in/someone/")
        #expect(run("  My email!  ") == "me@example.com")
    }
    @Test func cueInsideASentence() {
        #expect(run("Here is my email, thanks.") == "Here is me@example.com, thanks.")
        #expect(run("Send it to my work email today.") == "Send it to me@work.example today.")
    }
    @Test func notInsideOtherWords() {
        #expect(run("Check my emails later.") == "Check my emails later.")
        #expect(set.apply("Nothing here.").used == 0)
    }
    @Test func datesFilledIn() {
        #expect(run("Insert date.") == "18 November 2026")
        #expect(run("Today’s plan") == "1. Standup\n2. Review")
    }
    @Test func emptyShortAndDuplicateCuesDropped() {
        let s = SnippetSet([.init("  ", "x"), .init("hello", " "), .init("a", "x"), .init("My Email", "a"), .init("my email", "b")])
        #expect(s.snippets == [.init("My Email", "a")])
    }
    @Test func cueInsideASnippetsTextIsNotExpandedAgain() {
        let s = SnippetSet([.init("my signature", "Best, G.\nMy LinkedIn: see below"), .init("my linkedin", "https://x")])
        #expect(s.apply("Thanks, my signature").text == "Thanks, Best, G.\nMy LinkedIn: see below")
    }
    @Test func notAcrossSentencesOrAfterAHyphen() {
        let s = SnippetSet([.init("insert time", "{time}")])
        #expect(s.apply("Leave room to insert. Time is short.").used == 0)
        #expect(s.apply("We re-insert time codes.").used == 0)
    }
    @Test func onItsOwnOnly() {
        let s = SnippetSet(Snippet.defaults)
        #expect(s.apply("We need to insert time stamps into the log.").used == 0)
        #expect(s.apply("Insert time.", now: now, locale: Locale(identifier: "en_US")).text.hasSuffix("M"))
        #expect(!s.apply("Insert time.", now: now, locale: Locale(identifier: "en_US")).text.contains("\u{202F}"))
    }
    @Test func spacedCueMatchesJoinedWord() {
        let s = SnippetSet([.init("linked in", "L"), .init("e-mail me", "E")])
        #expect(s.apply("see my LinkedIn page").text == "see my L page")
        #expect(s.apply("please email me").text == "please E")
    }
    @Test func snippetSkipsPolish() async {
        var settings = CleanupSettings()
        settings.options.snippets = set
        settings.polishEnabled = true
        let r = await CleanupPipeline(polisher: nil).process("um my email", settings)
        #expect(r.text == "me@example.com" && !r.polished)
    }
}
