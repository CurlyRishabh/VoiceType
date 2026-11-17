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
    /// `tokenBudget`: apply the sherpa-onnx Whisper workaround above. whisper.cpp has no such cap
    /// (it seeks through each 30 s window by timestamps), so it gets plain <= 25 s chunks.
    public static func chunks(samples: [Float], segments: [Segment]?, whisper: Bool, language: String, tokenBudget: Bool = true) -> [[Float]] {
        let padding = tokenBudget && WhisperBudget.needsPadding(whisper: whisper, language: language)
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
        case .moonshine: return "Fast English (Moonshine, optional)"
        case .whisper: return "Speech model (Whisper: English + Hindi)"
        }
    }
}

/// Model files VoiceType knows by name: the one-click download, and checksums so an incomplete or
/// tampered download is refused at import.
public enum KnownModels {
    public struct Download: Sendable {
        public let fileName: String
        public let bytes: Int64
        public let sha256: String
        public let url: URL
        public var sizeText: String { "\(bytes / 1_000_000) MB" }
    }

    /// The default speech model: Whisper large-v3-turbo for whisper.cpp (English + Hindi, GPU).
    /// Served from this project's GitHub release; the size and SHA-256 are checked at import.
    public static let recommended = Download(
        fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        url: URL(string: "https://github.com/CurlyRishabh/VoiceType/releases/latest/download/ggml-large-v3-turbo-q5_0.bin")!)

    /// The official whisper.cpp model files, by name.
    public static let whisperCpp: [String: (bytes: Int64, sha256: String)] = [
        "ggml-large-v3-turbo-q5_0.bin": (574_041_195, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        "ggml-large-v3-turbo-q8_0.bin": (874_188_075, "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
        "ggml-large-v3-turbo.bin": (1_624_555_275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        "ggml-small.bin": (487_601_967, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        "ggml-small-q5_1.bin": (190_085_487, "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
    ]

    /// nil when the file is fine (or unknown); otherwise why it's rejected. `hash` is called only if the size matches.
    public static func problem(fileName: String, bytes: Int64, hash: () -> String?) -> String? {
        guard let known = whisperCpp[fileName] else { return nil }
        if bytes != known.bytes {
            return "\(fileName) is incomplete (\(bytes / 1_000_000) of \(known.bytes / 1_000_000) MB). Let the download finish, or download it again."
        }
        if hash() != known.sha256 { return "\(fileName) is damaged (checksum mismatch). Download it again." }
        return nil
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

    /// A whisper.cpp model (`ggml-*.bin`, Mac only) in the whisper folder. When present it is used
    /// instead of the sherpa-onnx Whisper files. Several: prefer a turbo model, then by name.
    public static func whisperCpp(_ dir: URL) -> URL? {
        let c = files(dir).filter { $0.pathExtension.lowercased() == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return c.first { $0.lastPathComponent.contains("turbo") } ?? c.first
    }

    /// "ggml-large-v3-turbo-q5_0.bin" -> "large-v3-turbo-q5_0".
    public static func whisperCppName(_ url: URL) -> String {
        let n = url.deletingPathExtension().lastPathComponent
        return n.hasPrefix("ggml-") ? String(n.dropFirst(5)) : n
    }

    public static func vad(_ dir: URL) -> URL? { files(dir).first { $0.pathExtension == "onnx" } }

    public static func isComplete(_ root: URL, _ slot: ModelSlot) -> Bool {
        let d = root.appendingPathComponent(slot.rawValue)
        switch slot {
        case .vad: return vad(d) != nil
        case .moonshine: return moonshine(d) != nil
        case .whisper: return whisper(d) != nil || whisperCpp(d) != nil
        }
    }

    public static func accepts(_ slot: ModelSlot, _ name: String) -> Bool {
        let n = name.lowercased()
        switch slot {
        case .vad: return n.hasSuffix(".onnx")
        case .moonshine: return n.hasSuffix(".onnx") || n.hasSuffix(".ort") || n == "tokens.txt"
        case .whisper: return n.hasSuffix(".onnx") || n.hasSuffix("tokens.txt") || n.hasSuffix(".bin")
        }
    }
}

/// The user's vocabulary as a Whisper initial prompt, so names like "Cassie QC agent" are
/// recognised directly instead of being fixed up afterwards.
public enum WhisperPrompt {
    /// Whisper reads at most ~224 prompt tokens; ~600 characters of names stays well inside that.
    public static let maxCharacters = 600

    /// Comma-separated glossary of the spellings the user wants ("Cassie QC agent, ChargeBee.").
    public static func build(_ terms: [String]) -> String? {
        var seen = Set<String>()
        var out: [String] = []
        var length = 0
        for t in terms {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, seen.insert(s.lowercased()).inserted else { continue }
            if length + s.count + 2 > maxCharacters { break }
            out.append(s)
            length += s.count + 2
        }
        return out.isEmpty ? nil : out.joined(separator: ", ") + "."
    }

    /// Whisper can "read back" its prompt when there is little real speech. Treat output made only of
    /// glossary terms (at least two of them) as that echo. A single term on its own is kept: saying
    /// just "Cassie QC agent" is a real dictation.
    public static func isEcho(_ text: String, prompt: String) -> Bool {
        let terms = prompt.split(separator: ",").map { normalize(String($0)) }.filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        var rest = " " + normalize(text) + " "
        var hits = 0
        for term in terms {
            while let r = rest.range(of: " \(term) ") {
                rest.replaceSubrange(r, with: " ")
                hits += 1
            }
        }
        return hits >= 2 && rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func normalize(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
