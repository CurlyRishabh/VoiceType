import Foundation

public let sampleRate = 16_000

public struct Segment: Sendable, Equatable {
    public let start: Int
    public let length: Int
    public init(start: Int, length: Int) { self.start = start; self.length = length }
    public var end: Int { start + length }
}

/// VAD segments -> decode chunks (merged when close, silence skipped, each <= 25 s). Same as Android.
public enum AudioChunker {
    public static let pad = sampleRate / 4
    public static let maxChunk = sampleRate * 25
    static let maxMergeGap = sampleRate * 3

    public static func plan(total: Int, segments: [Segment]?, maxChunk: Int = maxChunk) -> [Range<Int>] {
        guard total > 0 else { return [] }
        guard let segments else { return split(0..<total, maxChunk) }
        let padded = segments.sorted { $0.start < $1.start }
            .map { max(0, $0.start - pad)..<min(total, $0.end + pad) }
            .filter { !$0.isEmpty }
        var merged: [Range<Int>] = []
        for r in padded {
            if let last = merged.last, r.lowerBound - last.upperBound < maxMergeGap, r.upperBound - last.lowerBound <= maxChunk {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged.flatMap { split($0, maxChunk) }
    }

    static func split(_ r: Range<Int>, _ maxLen: Int) -> [Range<Int>] {
        stride(from: r.lowerBound, to: r.upperBound, by: maxLen).map { $0..<min($0 + maxLen, r.upperBound) }
    }
}

/// Works around sherpa-onnx's Whisper decoder budget of 6 output tokens per second of input
/// ("assume at most 6 tokens per second"). Devanagari needs ~3x that, so Hindi transcripts were
/// cut off mid-sentence. Fix: keep Hindi/auto chunks <= 8 s and append silence (zeros, exactly what
/// Whisper itself pads with) so the budget covers ~21 tokens per second of real speech.
public enum WhisperBudget {
    public static let tokensPerSecondNeeded = 21.0
    public static let sherpaTokensPerSecond = 6.0
    public static let maxPaddedSeconds = 29.0
    /// Longest real-speech chunk that still gets the full budget inside Whisper's 30 s window.
    public static let maxChunkSamples = sampleRate * 8

    public static func needsPadding(whisper: Bool, language: String) -> Bool { whisper && language != "en" }

    public static func paddedLength(_ count: Int) -> Int {
        let wanted = Double(count) * tokensPerSecondNeeded / sherpaTokensPerSecond
        let capped = min(wanted, maxPaddedSeconds * Double(sampleRate))
        return max(count, Int(capped))
    }

    public static func pad(_ chunk: [Float]) -> [Float] {
        let n = paddedLength(chunk.count)
        return n > chunk.count ? chunk + [Float](repeating: 0, count: n - chunk.count) : chunk
    }
}

/// Plans decode chunks for an utterance; shared by live dictation and the self-test.
public enum DecodePlan {
    public static func chunks(samples: [Float], segments: [Segment]?, whisper: Bool, language: String) -> [[Float]] {
        let padding = WhisperBudget.needsPadding(whisper: whisper, language: language)
        let maxChunk = padding ? WhisperBudget.maxChunkSamples : AudioChunker.maxChunk
        return AudioChunker.plan(total: samples.count, segments: segments, maxChunk: maxChunk).map { r in
            let c = Array(samples[r])
            return padding ? WhisperBudget.pad(c) : c
        }
    }
}

/// Drops Whisper's classic near-silence hallucinations.
public enum HallucinationFilter {
    static let tags = Rx("\\[[^\\]]*]|\\((?:[^)]*(?:music|applause|laughter|silence|noise|blank)[^)]*)\\)|[♪♫]+", ignoreCase: true)
    static let implausible: Set<String> = ["thanks for watching", "thank you for watching", "please subscribe", "subscribe", "like and subscribe", "you"]
    static let needsRealSpeech: Set<String> = ["thank you", "thanks", "thank you very much", "धन्यवाद", "शुक्रिया"]

    /// Collapses decoder loops: the same word or 2-3 word phrase repeated 4+ times in a row.
    public static func collapseRepeats(_ text: String) -> String {
        var t = text
        for n in [3, 2, 1] {
            let unit = Array(repeating: "\\S+", count: n).joined(separator: "\\s+")
            t = Rx("(?<!\\S)(\(unit))(?:\\s+\\1){3,}(?!\\S)").replace(t, "$1")
        }
        return t
    }

    public static func clean(_ text: String, speechMillis: Int) -> String {
        let stripped = collapseRepeats(Rx("\\s+").replace(tags.replace(text, " "), " ").trimmingCharacters(in: .whitespaces))
        let key = stripped.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if speechMillis < 1200 && implausible.contains(key) { return "" }
        if speechMillis < 300 && needsRealSpeech.contains(key) { return "" }
        return stripped
    }
}

/// Model files, identical layout to the Android app (and the `models/` folder next to it).
public enum ModelSlot: String, CaseIterable, Sendable {
    case vad, moonshine, whisper

    public var title: String {
        switch self {
        case .vad: return "Silero VAD (auto-stop)"
        case .moonshine: return "Fast English (Moonshine Base int8)"
        case .whisper: return "Hindi + English (Whisper small int8)"
        }
    }
}

public struct SpeechFiles: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case moonshineV1(preprocessor: String, encoder: String, uncached: String, cached: String)
        case moonshineV2(encoder: String, merged: String)
        case whisper(encoder: String, decoder: String)
    }
    public let kind: Kind
    public let tokens: String
}

public enum ModelLayout {
    static func files(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath }
    }

    static func preferInt8(_ c: [URL]) -> URL? { c.first { $0.lastPathComponent.contains("int8") } ?? c.first }

    public static func moonshine(_ dir: URL) -> SpeechFiles? {
        let f = files(dir)
        func named(_ p: String) -> [URL] { f.filter { $0.lastPathComponent.hasPrefix(p) } }
        guard let tokens = f.first(where: { $0.lastPathComponent == "tokens.txt" }) else { return nil }
        if let e = named("encoder_model").first, let d = named("decoder_model_merged").first {
            return SpeechFiles(kind: .moonshineV2(encoder: e.path, merged: d.path), tokens: tokens.path)
        }
        guard let p = named("preprocess").first, let e = preferInt8(named("encode")),
              let u = preferInt8(named("uncached_decode")), let c = preferInt8(named("cached_decode")) else { return nil }
        return SpeechFiles(kind: .moonshineV1(preprocessor: p.path, encoder: e.path, uncached: u.path, cached: c.path), tokens: tokens.path)
    }

    public static func whisper(_ dir: URL) -> SpeechFiles? {
        let f = files(dir)
        guard let e = preferInt8(f.filter { $0.lastPathComponent.contains("encoder") && $0.pathExtension == "onnx" }),
              let d = preferInt8(f.filter { $0.lastPathComponent.contains("decoder") && $0.pathExtension == "onnx" }),
              let t = f.first(where: { $0.lastPathComponent.hasSuffix("tokens.txt") }) else { return nil }
        return SpeechFiles(kind: .whisper(encoder: e.path, decoder: d.path), tokens: t.path)
    }

    public static func vad(_ dir: URL) -> URL? { files(dir).first { $0.pathExtension == "onnx" } }

    public static func isComplete(_ root: URL, _ slot: ModelSlot) -> Bool {
        let d = root.appendingPathComponent(slot.rawValue)
        switch slot {
        case .vad: return vad(d) != nil
        case .moonshine: return moonshine(d) != nil
        case .whisper: return whisper(d) != nil
        }
    }

    public static func accepts(_ slot: ModelSlot, _ name: String) -> Bool {
        let n = name.lowercased()
        switch slot {
        case .vad: return n.hasSuffix(".onnx")
        case .moonshine: return n.hasSuffix(".onnx") || n.hasSuffix(".ort") || n == "tokens.txt"
        case .whisper: return n.hasSuffix(".onnx") || n.hasSuffix("tokens.txt")
        }
    }
}
