import Foundation
import NIOCore
@testable import StockPlanBackend
import Testing
import Vapor

/// Request shaping and decoding only — no network.
@Suite("Groq transcription wire format")
struct GroqTranscriptionWireTests {
    private func rendered(_ body: MultipartBody) -> String {
        var buffer = body.finalized()
        return buffer.readString(length: buffer.readableBytes) ?? ""
    }

    @Test("The model travels as a form field, as the endpoint expects")
    func sendsModel() {
        let body = OpenAICompatibleTranscriptionProvider.requestBody(
            audio: [0x01], mimeType: "audio/ogg", model: "whisper-large-v3-turbo", hint: nil, boundary: "B"
        )
        #expect(rendered(body).contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
    }

    @Test("A ticker hint is sent as the decoding prompt")
    func sendsHint() {
        let body = OpenAICompatibleTranscriptionProvider.requestBody(
            audio: [0x01], mimeType: "audio/ogg", model: "m", hint: "NVDA AAPL", boundary: "B"
        )
        #expect(rendered(body).contains("name=\"prompt\"\r\n\r\nNVDA AAPL"))
    }

    @Test("No hint means no prompt field, not an empty one")
    func omitsEmptyHint() {
        // An empty prompt is not neutral — it is a real input to the decoder.
        let body = OpenAICompatibleTranscriptionProvider.requestBody(
            audio: [0x01], mimeType: "audio/ogg", model: "m", hint: "   ", boundary: "B"
        )
        #expect(!rendered(body).contains("name=\"prompt\""))
    }

    @Test("The filename extension follows the mime type the sender declared")
    func namesFileByMimeType() {
        #expect(OpenAICompatibleTranscriptionProvider.filename(for: "audio/ogg") == "audio.ogg")
        #expect(OpenAICompatibleTranscriptionProvider.filename(for: "audio/mpeg") == "audio.mp3")
        #expect(OpenAICompatibleTranscriptionProvider.filename(for: "audio/mp4") == "audio.m4a")
        // Telegram may omit it; ogg is what a voice note actually is.
        #expect(OpenAICompatibleTranscriptionProvider.filename(for: nil) == "audio.ogg")
    }

    @Test("A transcript is read out of the response")
    func decodesTranscript() throws {
        let json = #"{"text":"how is NVDA doing"}"#
        #expect(try OpenAICompatibleTranscriptionProvider.decodeTranscript(from: Data(json.utf8)) == "how is NVDA doing")
    }

    @Test("Surrounding whitespace is trimmed off the transcript")
    func trimsTranscript() throws {
        let json = #"{"text":"  hello  "}"#
        #expect(try OpenAICompatibleTranscriptionProvider.decodeTranscript(from: Data(json.utf8)) == "hello")
    }

    @Test("A response with no text field is an error, not an empty transcript")
    func rejectsMissingText() {
        #expect(throws: (any Error).self) {
            try OpenAICompatibleTranscriptionProvider.decodeTranscript(from: Data(#"{"error":"nope"}"#.utf8))
        }
    }
}

/// Voice is metered in seconds, not in calls: one 5-minute note costs what ten
/// short questions cost, and charging per call would let it through free.
@Suite("Voice daily budget", .serialized)
struct VoiceDailyCapTests {
    @Test("The default allowance is fifteen minutes a day")
    func defaultAllowance() {
        unsetenv("TRANSCRIBE_DAILY_SECONDS")
        #expect(VoiceDailyCap.dailySeconds == 900)
    }

    @Test("The allowance is tunable without a deploy")
    func overriddenAllowance() {
        setenv("TRANSCRIBE_DAILY_SECONDS", "120", 1)
        defer { unsetenv("TRANSCRIBE_DAILY_SECONDS") }
        #expect(VoiceDailyCap.dailySeconds == 120)
    }

    @Test("Nonsense in the environment falls back rather than disabling voice")
    func rejectsNonsense() {
        setenv("TRANSCRIBE_DAILY_SECONDS", "banana", 1)
        defer { unsetenv("TRANSCRIBE_DAILY_SECONDS") }
        #expect(VoiceDailyCap.dailySeconds == 900)
    }

    @Test("The counter is its own bucket, so voice cannot exhaust the chat allowance")
    func hasOwnBucket() {
        #expect(VoiceDailyCap.bucket != AIDailyCap.defaultBucket)
    }

    @Test("Running out says so in words the user can act on")
    func explainsExhaustion() {
        #expect(VoiceDailyCap.limitReachedReason.lowercased().contains("type"))
    }
}

/// Speech recognisers reliably mangle tickers — "NVDA" comes back as "in
/// vidia", "TSM" as "TSMC". Seeding the decoder with the symbols this user
/// actually follows is the cheapest accuracy the feature can buy.
@Suite("Transcription hint")
struct TranscriptionHintTests {
    @Test("Symbols become a prompt the decoder can bias on")
    func buildsPrompt() {
        let hint = TranscriptionHint.build(symbols: ["nvda", "aapl"])
        #expect(hint?.contains("NVDA") == true)
        #expect(hint?.contains("AAPL") == true)
    }

    @Test("No symbols means no prompt at all")
    func emptyIsNil() {
        #expect(TranscriptionHint.build(symbols: []) == nil)
        #expect(TranscriptionHint.build(symbols: ["  "]) == nil)
    }

    @Test("Duplicates are collapsed, case-insensitively")
    func dedupes() {
        let hint = TranscriptionHint.build(symbols: ["NVDA", "nvda", "NVDA"]) ?? ""
        #expect(hint.components(separatedBy: "NVDA").count == 2)
    }

    @Test("A huge watchlist is truncated rather than sent whole")
    func caps() {
        // The prompt is an input to the model; an unbounded one costs tokens
        // and stops helping.
        let many = (0 ..< 200).map { "SYM\($0)" }
        let hint = TranscriptionHint.build(symbols: many) ?? ""
        #expect(hint.count < 1000)
    }
}
