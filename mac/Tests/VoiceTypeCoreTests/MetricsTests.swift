import Foundation
import Testing
@testable import VoiceTypeCore

@Suite struct MetricsTests {
    @Test func perfectMatchIgnoresCaseAndPunctuation() {
        let s = ASRMetrics.wer(reference: "HE HOPED THERE WOULD BE STEW FOR DINNER",
                               hypothesis: "He hoped there would be stew for dinner.", language: "en")
        #expect(s == .init(errors: 0, refCount: 8))
    }
    @Test func countsSubstitutionDeletionInsertion() {
        // sat -> sit (S), "the" deleted (D), "down" inserted (I)
        let s = ASRMetrics.wer(reference: "the cat sat on the mat", hypothesis: "the cat sit on mat down", language: "en")
        #expect(s.errors == 3 && s.refCount == 6)
        #expect(abs(s.rate - 0.5) < 1e-9)
    }
    @Test func normalisesNumbersAndTitles() {
        #expect(ASRMetrics.wer(reference: "MISTER BROWN PAID TWENTY FIVE POUNDS",
                               hypothesis: "Mr. Brown paid 25 pounds", language: "en").errors == 0)
        // Known limit of the simple normaliser: years read as "eighteen forty" don't match "1840".
        #expect(ASRMetrics.wer(reference: "IN EIGHTEEN FORTY", hypothesis: "in 1840", language: "en").errors == 4)
        #expect(ASRMetrics.words("1984", language: "en") == ["one", "thousand", "nine", "hundred", "eighty", "four"])
        #expect(ASRMetrics.words("don't stop—well-known", language: "en") == ["don't", "stop", "well", "known"])
    }
    @Test func hindiKeepsDevanagariDropsDanda() {
        #expect(ASRMetrics.words("कल सुबह मीटिंग है।", language: "hi") == ["कल", "सुबह", "मीटिंग", "है"])
        let s = ASRMetrics.wer(reference: "कल सुबह मीटिंग है", hypothesis: "कल सुभह मीटिंग है।", language: "hi")
        #expect(s.errors == 1 && s.refCount == 4)
        let c = ASRMetrics.cer(reference: "कल सुबह मीटिंग है", hypothesis: "कल सुभह मीटिंग है", language: "hi")
        #expect(c.errors == 1) // one character differs
    }
    @Test func emptyCases() {
        #expect(ASRMetrics.wer(reference: "a b c", hypothesis: "", language: "en").errors == 3)
        #expect(ASRMetrics.wer(reference: "", hypothesis: "", language: "en").rate == 0)
        #expect((ASRMetrics.Score(errors: 1, refCount: 4) + .init(errors: 1, refCount: 6)).rate == 0.2)
    }
}

@Suite struct SafeJSONTests {
    struct Row: Codable, Equatable { let id: Int; let text: String }

    @Test func badEntrySkippedNotEverything() {
        let data = Data(#"[{"id":1,"text":"a"},{"id":"x"},{"id":3,"text":"c"}]"#.utf8)
        let r = SafeJSON.decodeArray(Row.self, from: data)
        #expect(r?.items == [Row(id: 1, text: "a"), Row(id: 3, text: "c")] && r?.dropped == 1)
    }

    @Test func damagedFileIsNotAList() {
        #expect(SafeJSON.decodeArray(Row.self, from: Data(#"[{"id":1,"text":"a"},{"id":2,"te"#.utf8)) == nil)
        #expect(SafeJSON.decodeArray(Row.self, from: Data()) == nil)
        #expect(SafeJSON.decodeArray(Row.self, from: Data("[]".utf8))?.items == [])
    }
}
