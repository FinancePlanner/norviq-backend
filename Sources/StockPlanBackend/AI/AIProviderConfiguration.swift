import Foundation
import Vapor

enum AIProviderKind: String, Sendable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case custom
}

/// Provider-neutral configuration for both Chat Completions and Responses API
/// workloads. OpenRouter is the multi-model production path because it
/// normalizes tool calling and Responses payloads across upstream providers.
struct AIProviderConfiguration: Sendable {
    private struct ProviderDefaults {
        let key: String
        let baseURL: String
        let model: String
        let tipsModel: String
    }

    let provider: AIProviderKind
    let apiKey: String
    let baseURL: String
    let defaultModel: String
    let chatModel: String
    let tipsModel: String
    let maxTokens: Int

    var isConfigured: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !defaultModel.isEmpty
    }

    static func load() -> Self {
        let provider = AIProviderKind(
            rawValue: (Environment.get("AI_PROVIDER") ?? "openai").lowercased()
        ) ?? .custom
        let defaults = switch provider {
        case .openAI:
            ProviderDefaults(
                key: Environment.get("OPENAI_API_KEY") ?? "",
                baseURL: "https://api.openai.com/v1",
                model: "gpt-5.6-terra",
                tipsModel: "gpt-5.6-luna"
            )
        case .openRouter:
            ProviderDefaults(
                key: Environment.get("OPENROUTER_API_KEY") ?? "",
                baseURL: "https://openrouter.ai/api/v1",
                model: "anthropic/claude-sonnet-4.6",
                tipsModel: "google/gemini-3.5-flash"
            )
        case .custom:
            ProviderDefaults(key: "", baseURL: "", model: "", tipsModel: "")
        }

        let legacyBaseURL = provider == .openAI ? Environment.get("OPENAI_BASE_URL") : nil
        let legacyModel = provider == .openAI ? Environment.get("OPENAI_MODEL") : nil
        let defaultModel = firstNonEmpty(
            Environment.get("AI_MODEL"),
            legacyModel,
            defaults.model
        )
        return Self(
            provider: provider,
            apiKey: firstNonEmpty(Environment.get("AI_API_KEY"), defaults.key),
            baseURL: firstNonEmpty(
                Environment.get("AI_BASE_URL"),
                legacyBaseURL,
                defaults.baseURL
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            defaultModel: defaultModel,
            chatModel: firstNonEmpty(Environment.get("AI_CHAT_MODEL"), defaultModel),
            tipsModel: firstNonEmpty(Environment.get("AI_TIPS_MODEL"), defaults.tipsModel, defaultModel),
            maxTokens: Environment.get("AI_MAX_TOKENS").flatMap(Int.init)
                ?? Environment.get("OPENAI_MAX_TOKENS").flatMap(Int.init)
                ?? 700
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
    }
}
