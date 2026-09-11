import Foundation
import NIOCore
import Vapor

/// Turns spoken audio into text.
///
/// Deliberately platform-agnostic: Telegram downloads the bytes itself, and an
/// app or web upload would hand over the same buffer.
protocol TranscriptionProvider: Sendable {
    /// False when no key is configured. The bot then says so rather than
    /// failing halfway through a turn.
    var isEnabled: Bool { get }

    /// - Parameter hint: Vocabulary to bias decoding toward — the user's own
    ///   tickers. Speech recognisers mangle symbols ("NVDA" becomes "in vidia"),
    ///   and this is the cheapest correction available.
    func transcribe(
        audio: ByteBuffer,
        mimeType: String?,
        hint: String?,
        on req: Request
    ) async throws -> String
}

/// Stands in when no key is configured, so a missing secret degrades one
/// feature instead of stopping the app from booting.
struct DisabledTranscriptionProvider: TranscriptionProvider {
    var isEnabled: Bool {
        false
    }

    func transcribe(audio _: ByteBuffer, mimeType _: String?, hint _: String?, on _: Request) async throws -> String {
        throw Abort(.serviceUnavailable, reason: "Voice transcription is not configured.")
    }
}

enum TranscriptionProviderFactory {
    /// `groq` keeps the variable names used by `secrets/horus/api-env-*.yaml`,
    /// so the two apps stay greppable together; `openai_compatible` is the
    /// self-hosted path, which needs a URL instead of a key.
    static func make() -> any TranscriptionProvider {
        switch (Environment.get("TRANSCRIBE_PROVIDER") ?? "groq").lowercased() {
        case "groq":
            // A hosted API without its key stays off rather than being called
            // anonymously and rejected on every single turn.
            guard let apiKey = Environment.get("TRANSCRIBE_PROVIDER_GROQ_APIKEY"), !apiKey.isEmpty else {
                return DisabledTranscriptionProvider()
            }
            return OpenAICompatibleTranscriptionProvider(
                apiKey: apiKey,
                baseURL: Environment.get("TRANSCRIBE_PROVIDER_GROQ_BASEURL")
                    ?? OpenAICompatibleTranscriptionProvider.groqBaseURL,
                model: Environment.get("TRANSCRIBE_PROVIDER_GROQ_MODEL")
                    ?? OpenAICompatibleTranscriptionProvider.groqDefaultModel
            )

        case "openai_compatible", "openai", "selfhosted", "self_hosted":
            // No URL means nothing to call; a guessed default would point at a
            // vendor the operator never asked for.
            guard let baseURL = Environment.get("TRANSCRIBE_PROVIDER_OPENAI_BASEURL"), !baseURL.isEmpty else {
                return DisabledTranscriptionProvider()
            }
            return OpenAICompatibleTranscriptionProvider(
                apiKey: Environment.get("TRANSCRIBE_PROVIDER_OPENAI_APIKEY") ?? "",
                baseURL: baseURL,
                model: Environment.get("TRANSCRIBE_PROVIDER_OPENAI_MODEL")
                    ?? OpenAICompatibleTranscriptionProvider.selfHostedDefaultModel
            )

        default:
            return DisabledTranscriptionProvider()
        }
    }
}
