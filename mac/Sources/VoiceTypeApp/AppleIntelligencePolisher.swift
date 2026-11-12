import Foundation
import FoundationModels
import VoiceTypeCore

/// Stage 2 polish with Apple's ON-DEVICE foundation model (`SystemLanguageModel.default`).
/// Deliberately never uses `PrivateCloudComputeLanguageModel` (server-side); the App Sandbox has no
/// network entitlement anyway. Unavailable (and skipped) if Apple Intelligence is off or unsupported.
final class AppleIntelligencePolisher: Polisher, @unchecked Sendable {

    var isReady: Bool {
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    var statusText: String {
        guard #available(macOS 26.0, *) else { return "Needs macOS 26 or later" }
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple on-device model: ready"
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use AI polish"
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence"
        case .unavailable(.modelNotReady): return "Apple's model is still downloading/preparing"
        case .unavailable: return "Apple on-device model unavailable"
        }
    }

    func warmUp() {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else { return }
        LanguageModelSession(model: .default).prewarm()
    }

    func polish(_ request: PolishRequest) async throws -> String {
        guard #available(macOS 26.0, *) else { throw EngineError("Apple foundation model needs macOS 26") }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: request.instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maxOutputTokens)
        return try await session.respond(to: request.userMessage, options: options).content
    }
}
