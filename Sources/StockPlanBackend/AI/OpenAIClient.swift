import Foundation
import Vapor

// MARK: - Wire models (OpenAI Chat Completions API)

struct OpenAIMessage: Content {
    var role: String // "system" | "user" | "assistant" | "tool"
    var content: String?
    var toolCalls: [OpenAIToolCall]?
    var toolCallId: String?
    var name: String?

    init(
        role: String,
        content: String? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

struct OpenAIToolCall: Content {
    var id: String
    var type: String
    var function: OpenAIFunctionCall
}

struct OpenAIFunctionCall: Content {
    var name: String
    /// JSON-encoded argument string. Our tools take no arguments, so this is "{}".
    var arguments: String
}

struct OpenAITool: Content {
    var type: String = "function"
    var function: OpenAIFunctionDef
}

struct OpenAIFunctionDef: Content {
    var name: String
    var description: String
    var parameters: OpenAIJSONSchema
}

/// All exposed tools take no arguments — the userId is bound server-side, never
/// passed by the model. So `properties` is always empty.
struct OpenAIJSONSchema: Content {
    var type: String = "object"
    var properties: [String: String] = [:]
    var required: [String] = []
}

struct OpenAIResponseFormat: Content {
    var type: String // "json_object" | "text"
}

private struct OpenAIChatRequestBody: Content {
    var model: String
    var messages: [OpenAIMessage]
    var tools: [OpenAITool]?
    var toolChoice: String?
    var temperature: Double?
    var maxTokens: Int?
    var responseFormat: OpenAIResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct OpenAIChatResponseBody: Content {
    var choices: [OpenAIChoice]
}

private struct OpenAIChoice: Content {
    var message: OpenAIMessage
    var finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

// MARK: - Client

/// One stateless chat completion. The tool-calling loop lives in the service,
/// which keeps this injectable + mockable in tests (no network).
protocol OpenAIChatClient: Sendable {
    func chat(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> OpenAIMessage
}

struct DefaultOpenAIChatClient: OpenAIChatClient {
    let apiKey: String
    let model: String
    let baseURL: String
    let maxTokens: Int

    func chat(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> OpenAIMessage {
        let body = OpenAIChatRequestBody(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            temperature: 0.3,
            maxTokens: maxTokens,
            responseFormat: responseFormat.map { OpenAIResponseFormat(type: $0) }
        )

        let uri = URI(string: "\(baseURL)/chat/completions")
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else {
            let bodyText = response.body.map { String(buffer: $0) } ?? ""
            req.logger.error("openai_error status=\(response.status.code) body=\(bodyText.prefix(500))")
            throw Abort(.badGateway, reason: "AI service is unavailable. Please try again later.")
        }

        let decoded = try response.content.decode(OpenAIChatResponseBody.self)
        guard let message = decoded.choices.first?.message else {
            throw Abort(.badGateway, reason: "AI service returned no result.")
        }
        return message
    }
}

/// Builds the chat client from environment config, falling back to a disabled
/// client when `OPENAI_API_KEY` is absent so the app still boots.
func makeOpenAIChatClient(_ app: Application) -> any OpenAIChatClient {
    guard let key = Environment.get("OPENAI_API_KEY"), !key.isEmpty else {
        app.logger.warning("OPENAI_API_KEY is not configured; AI insights are disabled.")
        return DisabledOpenAIChatClient()
    }
    return DefaultOpenAIChatClient(
        apiKey: key,
        model: Environment.get("OPENAI_MODEL") ?? "gpt-4.1-nano",
        baseURL: Environment.get("OPENAI_BASE_URL") ?? "https://api.openai.com/v1",
        maxTokens: Environment.get("OPENAI_MAX_TOKENS").flatMap(Int.init) ?? 700
    )
}

/// Used when no OPENAI_API_KEY is configured. Keeps the app bootable; the feature
/// simply reports itself unavailable instead of crashing at startup.
struct DisabledOpenAIChatClient: OpenAIChatClient {
    func chat(
        messages _: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat _: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        throw Abort(.serviceUnavailable, reason: "AI insights are not enabled on this server.")
    }
}
