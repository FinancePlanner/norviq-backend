import Foundation
import NIOCore
import Vapor

/// Speech to text over the OpenAI `POST /v1/audio/transcriptions` shape.
///
/// Named for the wire format rather than a vendor on purpose: a hosted API and
/// a self-hosted whisper server in this cluster are the same request with a
/// different base URL, and only the hosted one needs a key.
///
/// Every target of this shape takes Telegram's OGG/Opus as-is, which is why it
/// was chosen — there is no ffmpeg, no audio dependency and no transcoding
/// sidecar anywhere in this cluster, so a format conversion would have meant
/// new infrastructure.
struct OpenAICompatibleTranscriptionProvider: TranscriptionProvider {
    /// Empty for a self-hosted server, which sits behind a NetworkPolicy
    /// rather than an API key.
    let apiKey: String
    let baseURL: String
    let model: String

    static let groqBaseURL = "https://api.groq.com/openai/v1"
    static let groqDefaultModel = "whisper-large-v3-turbo"
    /// faster-whisper model ids are Hugging Face repos.
    static let selfHostedDefaultModel = "Systran/faster-whisper-small.en"
    /// A CPU-only server is far slower than a hosted GPU one.
    static let requestTimeout: TimeAmount = .seconds(120)

    var isEnabled: Bool {
        !baseURL.isEmpty
    }

    var authorization: BearerAuthorization? {
        apiKey.isEmpty ? nil : BearerAuthorization(token: apiKey)
    }

    func transcribe(
        audio: ByteBuffer,
        mimeType: String?,
        hint: String?,
        on req: Request
    ) async throws -> String {
        var audio = audio
        let bytes = audio.readBytes(length: audio.readableBytes) ?? []
        let body = Self.requestBody(audio: bytes, mimeType: mimeType, model: model, hint: hint)

        let uri = URI(string: "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/audio/transcriptions")
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.replaceOrAdd(name: .contentType, value: body.contentType)
            if let authorization {
                clientReq.headers.bearerAuthorization = authorization
            }
            clientReq.timeout = Self.requestTimeout
            clientReq.body = body.finalized()
        }

        guard response.status == .ok, var buffer = response.body else {
            // Never log the body verbatim — it can echo the key back.
            req.logger.error("transcription_failed status=\(response.status.code)")
            throw TranscriptionFailure.from(status: response.status.code)
        }
        return try Self.decodeTranscript(from: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
    }

    // MARK: - Wire format, split out so it can be asserted without a network call

    static func filename(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": "audio.mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "audio.m4a"
        case "audio/wav", "audio/x-wav": "audio.wav"
        case "audio/webm": "audio.webm"
        // Telegram often omits the type on a voice note; ogg is what it sends.
        default: "audio.ogg"
        }
    }

    static func requestBody(
        audio: [UInt8],
        mimeType: String?,
        model: String,
        hint: String?,
        boundary: String = "norviq-\(UUID().uuidString)"
    ) -> MultipartBody {
        var body = MultipartBody(boundary: boundary, reservingCapacity: audio.count + 512)
        body.addFile(
            name: "file",
            filename: filename(for: mimeType),
            contentType: mimeType ?? "audio/ogg",
            bytes: audio
        )
        body.addField(name: "model", value: model)
        body.addField(name: "response_format", value: "json")

        // An empty prompt is not neutral — it is still an input to the decoder.
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            body.addField(name: "prompt", value: hint)
        }
        return body
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    static func decodeTranscript(from data: Data) throws -> String {
        // A plain decoder on purpose: the app-wide `JSONDecoder.backendAPI` key
        // strategy rewrites keys before `CodingKeys` are consulted, which
        // breaks provider payloads. `TelegramClient` bypasses it for the same
        // reason.
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
