import Testing
@testable import VoiceTypeCore

@Suite struct ScreenNamesTests {
    static let vocabulary: Set<String> = ["channel", "home", "thanks", "slack", "new", "items", "today", "the", "files", "spec", "updated"]
    func names(_ sources: [String], limit: Int = 30) -> [String] {
        ScreenNames.extract(sources, isWord: { Self.vocabulary.contains($0) }, limit: limit)
    }

    @Test func slackWindow() {
        let found = names(["Dessi Tsvetkova (DM) - Rexera - 157 new items - Slack",
                           "Hi Kritant",
                           "Channel | Home | Files | Rishabh Bisht | Thanks Dessi, I’ve updated the spec. | Rishabh’s VoiceType | API | DM"])
        #expect(found == ["Dessi", "Tsvetkova", "Rexera", "Kritant", "Rishabh", "Bisht", "VoiceType"])
    }
    @Test func innerCapitalsKeptEvenIfAWord() {
        #expect(names(["iPhone and GitHub and macOS"]) == ["iPhone", "GitHub", "macOS"])
    }
    @Test func moreFrequentFirstAndCapped() {
        #expect(names(["Asha Neel Neel Mahesh Mahesh Mahesh"], limit: 2) == ["Mahesh", "Neel"])
    }
    @Test func lowerCaseAndShortWordsSkipped() {
        #expect(names(["sasidhar ok Al Bo the Today"]).isEmpty)
    }
}

@Suite struct ScreenPromptTests {
    @Test func namesFirstDictionaryLastAndCapped() {
        let p = WhisperPrompt.build(["Cassie QC agent"], extra: ["Kritant", "cassie qc agent", String(repeating: "x", count: 300)])
        #expect(p == "Kritant, Cassie QC agent.")
    }
    @Test func twoNamesSaidAreNotAnEcho() {
        let prompt = WhisperPrompt.build([], extra: ["Dessi", "Tsvetkova"])!
        #expect(WhisperPrompt.isEcho("Dessi Tsvetkova", prompt: prompt)) // looks like one…
        #expect(WhisperPrompt.sameSpeech("Dessi Tsvetkova", "Desi Svetkova")) // …but it was said
        #expect(!WhisperPrompt.sameSpeech("Cassie QC agent, ChargeBee.", ""))
        #expect(!WhisperPrompt.sameSpeech("Cassie QC agent, ChargeBee.", "Thank you."))
    }
}
