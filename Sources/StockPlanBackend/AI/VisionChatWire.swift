import Foundation
import Vapor

// MARK: - Vision request wire model (multimodal content array)

/// The OpenAI chat-completions request shape with a *multimodal content array*.
///
/// The assistant's own `OpenAIMessage.content` is a plain string and cannot carry
/// an image, so every vision feature needs this shape instead. It lives here
/// rather than beside a single provider because there is now more than one
/// caller (receipt OCR, portfolio screenshots) and a per-feature copy would drift.
struct VisionRequest: Content {
    var model: String
    var messages: [VisionMessage]
    var temperature: Double
    var maxTokens: Int
    var responseFormat: ResponseFormat

    struct ResponseFormat: Content {
        var type: String

        static let json = ResponseFormat(type: "json_object")
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

struct VisionMessage: Content {
    var role: String
    var content: [VisionContentPart]
}

/// A single content part — either a text span or an image reference. Encodes to
/// the OpenAI chat multimodal shape (`{"type":"text",...}` / `{"type":"image_url",...}`).
enum VisionContentPart: Content {
    case text(String)
    case imageURL(String)

    /// Wraps raw image bytes as a base64 `data:` URL, defaulting an unknown or
    /// absent content type to JPEG the way the upload endpoints do.
    static func image(data: Data, contentType: String) -> VisionContentPart {
        let mime = contentType.isEmpty || contentType == "application/octet-stream" ? "image/jpeg" : contentType
        return .imageURL("data:\(mime);base64,\(data.base64EncodedString())")
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURL: Content {
        var url: String
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "image_url" {
            self = try .imageURL(container.decode(ImageURL.self, forKey: .imageURL).url)
        } else {
            self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
        }
    }
}

struct VisionResponse: Content {
    var choices: [Choice]

    struct Choice: Content {
        var message: Message
    }

    struct Message: Content {
        var content: String?
    }
}

// MARK: - Shared call path

/// Posts a vision request and returns the model's JSON text.
///
/// Both vision features want identical behaviour on the wire: strict JSON mode,
/// a logged non-200 that surfaces as a 502 rather than leaking the provider's
/// body, and provider payloads decoded through
/// `DefaultOpenAIChatClient.decodeProviderJSON` — the global API decoder eats
/// explicitly mapped snake_case keys.
enum VisionChatCaller {
    static func completeJSON(
        _ body: VisionRequest,
        apiKey: String,
        baseURL: String,
        feature: String,
        on req: Request
    ) async throws -> String? {
        let uri = URI(string: "\(baseURL)/chat/completions")
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else {
            let bodyText = response.body.map { String(buffer: $0) } ?? ""
            req.logger.error("\(feature)_error status=\(response.status.code) body=\(bodyText.prefix(300))")
            throw Abort(.badGateway, reason: "\(feature.replacingOccurrences(of: "_", with: " ").capitalized) is temporarily unavailable. Please try again.")
        }

        let decoded = try DefaultOpenAIChatClient.decodeProviderJSON(
            VisionResponse.self,
            from: response,
            logger: req.logger
        )
        return decoded.choices.first?.message.content
    }
}
