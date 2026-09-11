import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

/// The provider can fail for reasons that mean very different things to a user.
/// "I couldn't make that out" after a 402 tells them they mumbled, when in fact
/// the account ran dry — they would keep re-recording a clip that can never work.
@Suite("Transcription failure mapping")
struct TranscriptionFailureTests {
    @Test("Payment and auth failures mean the feature is off, not the audio bad")
    func creditsExhausted() {
        #expect(TranscriptionFailure.from(status: 402) == .unavailable)
        #expect(TranscriptionFailure.from(status: 401) == .unavailable)
        #expect(TranscriptionFailure.from(status: 403) == .unavailable)
    }

    @Test("Rate limiting is temporary and says so")
    func rateLimited() {
        #expect(TranscriptionFailure.from(status: 429) == .busy)
    }

    @Test("Anything else is a genuine transcription failure")
    func otherFailures() {
        #expect(TranscriptionFailure.from(status: 500) == .failed)
        #expect(TranscriptionFailure.from(status: 400) == .failed)
    }

    @Test("The unavailable message tells the user to type instead of re-recording")
    func unavailableWording() {
        let message = TranscriptionFailure.unavailable.message.lowercased()
        #expect(message.contains("type"))
        // Must not blame the recording.
        #expect(!message.contains("make that out"))
    }

    @Test("The busy message invites a retry")
    func busyWording() {
        #expect(TranscriptionFailure.busy.message.lowercased().contains("again"))
    }

    @Test("Each failure says something different")
    func messagesAreDistinct() {
        let all = Set([
            TranscriptionFailure.unavailable.message,
            TranscriptionFailure.busy.message,
            TranscriptionFailure.failed.message,
        ])
        #expect(all.count == 3)
    }
}

/// The endpoint shape, not the vendor, is what the code depends on: Groq, a
/// self-hosted whisper server and anything else speaking
/// `POST /v1/audio/transcriptions` are one provider with different URLs.
@Suite("Transcription provider selection, neutral naming", .serialized)
struct NeutralProviderSelectionTests {
    private func clear() {
        for key in ["TRANSCRIBE_PROVIDER",
                    "TRANSCRIBE_PROVIDER_GROQ_APIKEY", "TRANSCRIBE_PROVIDER_GROQ_BASEURL",
                    "TRANSCRIBE_PROVIDER_GROQ_MODEL",
                    "TRANSCRIBE_PROVIDER_OPENAI_APIKEY", "TRANSCRIBE_PROVIDER_OPENAI_BASEURL",
                    "TRANSCRIBE_PROVIDER_OPENAI_MODEL"]
        {
            unsetenv(key)
        }
    }

    @Test("A self-hosted server needs a URL and no key at all")
    func selfHostedNeedsNoKey() {
        clear()
        setenv("TRANSCRIBE_PROVIDER", "openai_compatible", 1)
        setenv("TRANSCRIBE_PROVIDER_OPENAI_BASEURL", "http://whisper.transcription.svc.cluster.local:8000/v1", 1)
        setenv("TRANSCRIBE_PROVIDER_OPENAI_MODEL", "Systran/faster-whisper-small.en", 1)
        defer { clear() }

        let provider = TranscriptionProviderFactory.make() as? OpenAICompatibleTranscriptionProvider
        #expect(provider?.isEnabled == true)
        #expect(provider?.apiKey.isEmpty == true)
        #expect(provider?.model == "Systran/faster-whisper-small.en")
    }

    @Test("Without a base URL there is nothing to call, so it stays disabled")
    func selfHostedNeedsURL() {
        clear()
        setenv("TRANSCRIBE_PROVIDER", "openai_compatible", 1)
        defer { clear() }
        #expect(!TranscriptionProviderFactory.make().isEnabled)
    }

    @Test("Groq still works, as the same shape with a key and its own default URL")
    func groqStillSupported() {
        clear()
        setenv("TRANSCRIBE_PROVIDER", "groq", 1)
        setenv("TRANSCRIBE_PROVIDER_GROQ_APIKEY", "gsk_test", 1)
        defer { clear() }

        let provider = TranscriptionProviderFactory.make() as? OpenAICompatibleTranscriptionProvider
        #expect(provider?.isEnabled == true)
        #expect(provider?.baseURL.contains("groq.com") == true)
    }

    @Test("A hosted provider named without its key is disabled, not called keyless")
    func groqWithoutKeyDisabled() {
        clear()
        setenv("TRANSCRIBE_PROVIDER", "groq", 1)
        defer { clear() }
        #expect(!TranscriptionProviderFactory.make().isEnabled)
    }

    @Test("With nothing configured the feature is off and the app still boots")
    func disabledWithoutConfiguration() {
        clear()
        #expect(!TranscriptionProviderFactory.make().isEnabled)
    }

    @Test("Groq's base URL and model stay overridable, matching the Horus config shape")
    func honoursGroqOverrides() {
        clear()
        setenv("TRANSCRIBE_PROVIDER", "groq", 1)
        setenv("TRANSCRIBE_PROVIDER_GROQ_APIKEY", "gsk_test", 1)
        setenv("TRANSCRIBE_PROVIDER_GROQ_BASEURL", "https://example.test/openai/v1", 1)
        setenv("TRANSCRIBE_PROVIDER_GROQ_MODEL", "whisper-tiny", 1)
        defer { clear() }

        let provider = TranscriptionProviderFactory.make() as? OpenAICompatibleTranscriptionProvider
        #expect(provider?.baseURL == "https://example.test/openai/v1")
        #expect(provider?.model == "whisper-tiny")
    }

    @Test("An unknown provider name disables rather than guessing")
    func unknownProviderDisables() {
        clear()
        setenv("TRANSCRIBE_PROVIDER", "nonsense", 1)
        setenv("TRANSCRIBE_PROVIDER_GROQ_APIKEY", "gsk_test", 1)
        defer { clear() }
        #expect(!TranscriptionProviderFactory.make().isEnabled)
    }

    @Test("Only a configured key produces an Authorization header")
    func authorizationIsOptional() {
        #expect(OpenAICompatibleTranscriptionProvider(
            apiKey: "", baseURL: "http://x/v1", model: "m"
        ).authorization == nil)
        #expect(OpenAICompatibleTranscriptionProvider(
            apiKey: "k", baseURL: "http://x/v1", model: "m"
        ).authorization != nil)
    }
}

/// The bridge sees `any Error`, so the mapping has to survive the crossing —
/// a typed failure that decays to the generic message on the way out would
/// make the distinction pointless.
@Suite("Bridge failure wording")
struct BridgeFailureWordingTests {
    @Test("A typed failure keeps its own wording")
    func typedFailuresKeepWording() {
        #expect(TelegramBridge.transcriptionFailureMessage(for: TranscriptionFailure.unavailable)
            == TranscriptionFailure.unavailable.message)
        #expect(TelegramBridge.transcriptionFailureMessage(for: TranscriptionFailure.busy)
            == TranscriptionFailure.busy.message)
    }

    @Test("An unrelated error falls back to the generic wording")
    func unknownErrorsFallBack() {
        struct Boom: Error {}
        #expect(TelegramBridge.transcriptionFailureMessage(for: Boom())
            == TranscriptionFailure.failed.message)
    }

    @Test("A download failure is not reported as out of credit")
    func transportErrorsAreNotCreditErrors() {
        // getFile/download failures arrive as TelegramError and must not claim
        // the account is out of credit.
        let message = TelegramBridge.transcriptionFailureMessage(
            for: TelegramClient.TelegramError.http(500)
        )
        #expect(message == TranscriptionFailure.failed.message)
    }
}
