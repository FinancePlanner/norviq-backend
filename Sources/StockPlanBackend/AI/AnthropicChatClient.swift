import Foundation
import NIOCore
import Vapor

// MARK: - Options

/// The knobs the Anthropic rung takes beyond what every tier has.
struct AnthropicMessagesOptions: Sendable, Equatable {
    /// `output_config.effort`. Nil omits the field, which leaves the model's
    /// own default in force.
    var effort: String?
    /// False sends `thinking: {type: "disabled"}` on every request.
    var thinkingEnabled: Bool = true
}

// MARK: - Wire models (Anthropic Messages API)

/// One turn of a Messages API transcript. Content is kept as raw JSON blocks so
/// thinking blocks round-trip byte-for-byte in meaning, whatever fields the API
/// adds to them later.
struct AnthropicTurn: Encodable, Equatable {
    var role: String
    var content: [OpenAIJSONValue]
}

struct AnthropicToolDefinition: Encodable {
    var name: String
    var description: String
    var inputSchema: OpenAIJSONSchema

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

struct AnthropicOutputConfig: Encodable, Equatable {
    var effort: String
}

/// The request body. There is deliberately no `temperature`, `top_p` or
/// `top_k`: Claude Haiku 5.5 answers any non-default sampling value with a 400.
struct AnthropicMessagesRequest: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var messages: [AnthropicTurn]
    var tools: [AnthropicToolDefinition]?
    var toolChoice: OpenAIJSONValue?
    var thinking: OpenAIJSONValue
    var outputConfig: AnthropicOutputConfig?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, thinking
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case outputConfig = "output_config"
    }

    var thinkingEnabled: Bool {
        thinking != AnthropicChatClient.thinkingDisabled
    }
}

struct AnthropicMessagesResponse: Decodable {
    struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    var id: String?
    var model: String?
    var content: [OpenAIJSONValue]
    var stopReason: String?
    var stopDetails: OpenAIJSONValue?
    var usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, model, content, usage
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }
}

// MARK: - Client

/// Claude through Anthropic's own Messages API, behind the same
/// `OpenAIChatClient` seam every other rung uses.
///
/// Raw HTTP on purpose: there is no official Anthropic Swift SDK. The services
/// keep speaking the OpenAI chat shape; everything Anthropic-specific — the
/// top-level system prompt, `tool_use`/`tool_result` blocks, thinking replay,
/// refusals — is translated here, in static functions the tests drive without a
/// network.
///
/// Every failure throws, so `FallbackChatClient` demotes to the OpenRouter
/// chain behind it: a non-2xx (spend cap and bad key included) and a refusal
/// both surface as `OpenAIChatUpstreamError`.
struct AnthropicChatClient: OpenAIChatClient {
    let apiKey: String
    let model: String
    let baseURL: String
    let maxTokens: Int
    let options: AnthropicMessagesOptions
    let timeout: TimeAmount

    static let apiVersion = "2023-06-01"
    static let defaultBaseURL = "https://api.anthropic.com"

    /// Under this many output tokens there is no room to think and still
    /// answer, so thinking is switched off for the request.
    static let minimumThinkingMaxTokens = 1024

    /// The `type` of the one `reasoningDetails` entry this client writes onto
    /// every message it returns. It carries the turn's raw thinking blocks.
    ///
    /// Namespaced rather than shaped like OpenRouter's own entries so neither
    /// side mistakes the other's: `DefaultOpenAIChatClient` strips it, and this
    /// client treats an assistant tool turn *without* it as one another rung
    /// produced, whose reasoning cannot be replayed.
    static let reasoningMarkerType = "norviq.anthropic.thinking"

    static let jsonInstruction = "Respond with a single JSON object, no code fences."
    static let continuePrompt = "Continue."

    static let thinkingDisabled: OpenAIJSONValue = .object(["type": .string("disabled")])
    static let thinkingAdaptive: OpenAIJSONValue = .object(["type": .string("adaptive")])

    init(
        apiKey: String,
        model: String,
        baseURL: String = AnthropicChatClient.defaultBaseURL,
        maxTokens: Int,
        options: AnthropicMessagesOptions = AnthropicMessagesOptions(),
        timeout: TimeAmount = .seconds(60)
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.options = options
        self.timeout = timeout
    }

    func chat(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> OpenAIMessage {
        var rounds = 0
        let message = try await DefaultOpenAIChatClient.completeResumingTruncation(
            messages: messages,
            responseFormat: responseFormat,
            model: model,
            logger: req.logger
        ) { transcript in
            rounds += 1
            return try await completion(
                messages: transcript,
                tools: tools,
                responseFormat: responseFormat,
                on: req
            )
        }
        // A resumed answer stitches two completions together, and the thinking
        // it carries was produced after a transcript that no longer exists.
        // Replaying it would be rejected, so drop the marker: the next request
        // then sees a turn without thinking and switches thinking off instead.
        guard rounds > 1 else { return message }
        var stitched = message
        stitched.reasoningDetails = nil
        return stitched
    }

    /// One round trip to the Messages API.
    private func completion(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> DefaultOpenAIChatClient.Completion {
        let body = Self.makeRequest(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            model: model,
            maxTokens: maxTokens,
            options: options
        )
        let data = try Self.encoder.encode(body)

        let uri = URI(string: "\(baseURL)/v1/messages")
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.replaceOrAdd(name: "x-api-key", value: apiKey)
            clientReq.headers.replaceOrAdd(name: "anthropic-version", value: Self.apiVersion)
            clientReq.timeout = timeout
            clientReq.body = ByteBuffer(bytes: data)
        }

        guard (200 ..< 300).contains(response.status.code) else {
            let bodyText = response.body.map { String(buffer: $0) } ?? ""
            let safeBody = bodyText.contains(apiKey) ? "<redacted: contained the key>" : String(bodyText.prefix(500))
            let status = Self.upstreamStatus(httpStatus: response.status.code, body: bodyText)
            req.logger.error("anthropic_error status=\(response.status.code) classified=\(status) body=\(safeBody)")
            throw OpenAIChatUpstreamError(upstreamStatus: status)
        }

        let decoded = try DefaultOpenAIChatClient.decodeProviderJSON(
            AnthropicMessagesResponse.self, from: response, logger: req.logger
        )
        let result: DefaultOpenAIChatClient.Completion
        do {
            result = try Self.translateResponse(decoded, responseFormat: responseFormat)
        } catch {
            req.logger.warning("anthropic_refusal", metadata: [
                "model": "\(decoded.model ?? model)",
                "details": "\(decoded.stopDetails.map { String(describing: $0) } ?? "none")",
            ])
            throw error
        }
        Self.logCompletion(decoded, result: result, fallbackModel: model, thinking: body.thinkingEnabled, logger: req.logger)
        return result
    }

    // MARK: - Request translation

    /// Builds the Messages API body from an OpenAI-shaped transcript.
    static func makeRequest(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        model: String,
        maxTokens: Int,
        options: AnthropicMessagesOptions
    ) -> AnthropicMessagesRequest {
        // The final "answer now" call sends no tools over a transcript full of
        // tool turns. `tool_use` blocks are rejected without the matching tool
        // definitions, so those turns are flattened into plain text instead.
        let flattenTools = tools.isEmpty && containsToolTurns(messages)
        let thinking = !flattenTools && shouldThink(
            messages: messages, maxTokens: maxTokens, options: options
        )

        var systemParts = messages
            .filter { $0.role == "system" }
            .compactMap { nonEmpty($0.content) }
        if responseFormat == "json_object" {
            systemParts.append(jsonInstruction)
        }

        let turns = makeTurns(
            messages: messages.filter { $0.role != "system" },
            flattenTools: flattenTools,
            replayThinking: thinking
        )

        // Effort above `high` is rejected with thinking off.
        let effort = options.effort.map { effort in
            !thinking && ["xhigh", "max"].contains(effort) ? "high" : effort
        }

        return AnthropicMessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            messages: turns,
            tools: tools.isEmpty ? nil : tools.map {
                AnthropicToolDefinition(
                    name: $0.function.name,
                    description: $0.function.description,
                    inputSchema: $0.function.parameters
                )
            },
            toolChoice: tools.isEmpty ? nil : .object(["type": .string("auto")]),
            thinking: thinking ? thinkingAdaptive : thinkingDisabled,
            outputConfig: effort.map { AnthropicOutputConfig(effort: $0) }
        )
    }

    /// Whether this request can run with thinking on.
    ///
    /// In a tool loop the API wants every earlier assistant tool turn sent back
    /// with its thinking blocks. A turn that another rung produced has none to
    /// send, so one such turn turns thinking off for the whole request.
    static func shouldThink(
        messages: [OpenAIMessage],
        maxTokens: Int,
        options: AnthropicMessagesOptions
    ) -> Bool {
        guard options.thinkingEnabled, maxTokens >= minimumThinkingMaxTokens else { return false }
        return messages.allSatisfy { message in
            guard message.role == "assistant", message.toolCalls?.isEmpty == false else { return true }
            return thinkingBlocks(in: message) != nil
        }
    }

    static func containsToolTurns(_ messages: [OpenAIMessage]) -> Bool {
        messages.contains { message in
            message.role == "tool" || (message.role == "assistant" && message.toolCalls?.isEmpty == false)
        }
    }

    /// Turns the non-system messages into alternating Messages API turns that
    /// end on a user turn.
    static func makeTurns(
        messages: [OpenAIMessage],
        flattenTools: Bool,
        replayThinking: Bool
    ) -> [AnthropicTurn] {
        var turns: [AnthropicTurn] = []

        func append(_ role: String, _ blocks: [OpenAIJSONValue]) {
            guard !blocks.isEmpty else { return }
            if turns.last?.role == role {
                turns[turns.count - 1].content.append(contentsOf: blocks)
            } else {
                turns.append(AnthropicTurn(role: role, content: blocks))
            }
        }

        for message in messages {
            switch message.role {
            case "assistant":
                var blocks: [OpenAIJSONValue] = []
                if replayThinking, let thinking = thinkingBlocks(in: message) {
                    blocks.append(contentsOf: thinking)
                }
                if let text = nonEmpty(message.content) {
                    blocks.append(textBlock(text))
                }
                for call in message.toolCalls ?? [] {
                    if flattenTools {
                        blocks.append(textBlock("[Called tool \(call.function.name) with arguments \(call.function.arguments)]"))
                    } else {
                        blocks.append(.object([
                            "type": .string("tool_use"),
                            "id": .string(call.id),
                            "name": .string(call.function.name),
                            "input": toolInput(call.function.arguments),
                        ]))
                    }
                }
                // Thinking alone is not a turn worth sending.
                if blocks.contains(where: { !isThinkingBlock($0) }) {
                    append("assistant", blocks)
                }

            case "tool":
                let output = message.content ?? ""
                if flattenTools {
                    append("user", [textBlock("[Result of tool \(message.name ?? "call")]: \(output)")])
                } else {
                    var block: [String: OpenAIJSONValue] = [
                        "type": .string("tool_result"),
                        "tool_use_id": .string(message.toolCallId ?? ""),
                    ]
                    if !output.isEmpty {
                        block["content"] = .string(output)
                    }
                    append("user", [.object(block)])
                }

            default:
                if let text = nonEmpty(message.content) {
                    append("user", [textBlock(text)])
                }
            }
        }

        // No prefill on this model: the transcript has to end on the user.
        if turns.last?.role != "user" {
            append("user", [textBlock(continuePrompt)])
        }
        return turns
    }

    /// Tool arguments arrive as a JSON string; the API wants an object.
    static func toolInput(_ arguments: String) -> OpenAIJSONValue {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .object([:])
        }
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(OpenAIJSONValue.self, from: data),
           case .object = value
        {
            return value
        }
        return .object(["_raw": .string(arguments)])
    }

    /// The thinking blocks this client stashed on an assistant message, or nil
    /// when the message did not come from this client.
    static func thinkingBlocks(in message: OpenAIMessage) -> [OpenAIJSONValue]? {
        for entry in message.reasoningDetails ?? [] {
            guard case let .object(fields) = entry,
                  fields["type"] == .string(reasoningMarkerType)
            else { continue }
            if case let .array(blocks) = fields["blocks"] {
                return blocks
            }
            return []
        }
        return nil
    }

    // MARK: - Response translation

    /// Maps a Messages API response onto the OpenAI-shaped message the services
    /// consume.
    ///
    /// Throws on a refusal: it arrives as a 200 with nothing usable, and the
    /// chain has to move on to the next rung rather than show the user an empty
    /// answer.
    static func translateResponse(
        _ response: AnthropicMessagesResponse,
        responseFormat: String?
    ) throws -> DefaultOpenAIChatClient.Completion {
        if response.stopReason == "refusal" {
            throw OpenAIChatUpstreamError(upstreamStatus: 200)
        }

        var text = ""
        var toolCalls: [OpenAIToolCall] = []
        var thinking: [OpenAIJSONValue] = []
        for block in response.content {
            guard case let .object(fields) = block, case let .string(type) = fields["type"] else { continue }
            switch type {
            case "text":
                if case let .string(value) = fields["text"] {
                    text += value
                }
            case "tool_use":
                guard case let .string(id) = fields["id"], case let .string(name) = fields["name"] else { continue }
                toolCalls.append(OpenAIToolCall(
                    id: id,
                    type: "function",
                    function: OpenAIFunctionCall(name: name, arguments: encodeArguments(fields["input"]))
                ))
            case "thinking", "redacted_thinking":
                thinking.append(block)
            default:
                continue
            }
        }

        let finishReason: String = switch response.stopReason {
        case "tool_use": "tool_calls"
        case "max_tokens", "model_context_window_exceeded": "length"
        default: "stop"
        }
        // A tool call cut off by the cap carries half-written input. Acting on
        // it would be worse than not calling at all.
        if finishReason == "length" {
            toolCalls = []
        }
        if responseFormat == "json_object" {
            text = extractJSONObject(text)
        }

        let message = OpenAIMessage(
            role: "assistant",
            content: text.isEmpty && !toolCalls.isEmpty ? nil : text,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            reasoningDetails: [.object([
                "type": .string(reasoningMarkerType),
                "blocks": .array(thinking),
            ])]
        )
        return DefaultOpenAIChatClient.Completion(message: message, finishReason: finishReason)
    }

    /// Pulls the JSON object out of a reply that may wrap it in code fences or
    /// a sentence of preamble.
    static func extractJSONObject(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst()
                .joined(separator: "\n")
            if let fence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<fence.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let open = trimmed.firstIndex(of: "{"),
              let close = trimmed.lastIndex(of: "}"),
              open < close
        else { return trimmed }
        return String(trimmed[open ... close])
    }

    // MARK: - Errors

    /// The status recorded on `OpenAIChatUpstreamError`.
    ///
    /// The API reports a spent workspace limit as a plain 400. Reclassified as
    /// 402 so the chain's logs and alerts read it as out of credits — which is
    /// what it is — rather than as a malformed request.
    static func upstreamStatus(httpStatus: UInt, body: String) -> UInt {
        guard httpStatus == 400 else { return httpStatus }
        let lowered = body.lowercased()
        if lowered.contains("usage limit") || lowered.contains("credit balance") {
            return 402
        }
        return httpStatus
    }

    // MARK: - Metering

    /// Estimated cost in millionths of a dollar for Claude Haiku 5.5:
    /// $0.10 / $0.50 per million input / output tokens, five times that once
    /// the prompt passes 100K tokens. Cache reads bill at 0.1× input and cache
    /// writes at 1.25×.
    static func estimatedCostMicros(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) -> Int {
        let promptTokens = inputTokens + cacheReadTokens + cacheCreationTokens
        let multiplier = promptTokens > 100_000 ? 5.0 : 1.0
        let micros = Double(inputTokens) * 0.10
            + Double(cacheCreationTokens) * 0.125
            + Double(cacheReadTokens) * 0.01
            + Double(outputTokens) * 0.50
        return Int((micros * multiplier).rounded())
    }

    /// The same `ai_completion` line `DefaultOpenAIChatClient` writes, plus the
    /// cache and cost fields the trial is judged on.
    private static func logCompletion(
        _ response: AnthropicMessagesResponse,
        result: DefaultOpenAIChatClient.Completion,
        fallbackModel: String,
        thinking: Bool,
        logger: Logger
    ) {
        let input = response.usage?.inputTokens ?? 0
        let output = response.usage?.outputTokens ?? 0
        let cacheRead = response.usage?.cacheReadInputTokens ?? 0
        let cacheCreation = response.usage?.cacheCreationInputTokens ?? 0
        let prompt = input + cacheRead + cacheCreation
        let responseModel = response.model ?? fallbackModel
        let finishReason = result.finishReason ?? "unknown"
        logger.info("ai_completion", metadata: [
            "provider": "anthropic",
            "model": "\(responseModel)",
            "finish_reason": "\(finishReason)",
            "stop_reason": "\(response.stopReason ?? "unknown")",
            "prompt_tokens": "\(response.usage == nil ? -1 : prompt)",
            "completion_tokens": "\(response.usage?.outputTokens ?? -1)",
            "total_tokens": "\(response.usage == nil ? -1 : prompt + output)",
            // The API does not split thinking out of output tokens.
            "reasoning_tokens": "-1",
            "content_chars": "\(result.message.content?.count ?? 0)",
            "tool_calls": "\(result.message.toolCalls?.count ?? 0)",
            "cache_read_tokens": "\(cacheRead)",
            "cache_creation_tokens": "\(cacheCreation)",
            "est_cost_usd_micros": "\(estimatedCostMicros(inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheCreationTokens: cacheCreation))",
            "thinking": "\(thinking)",
        ])
        if result.message.hasNoUsableOutput {
            logger.warning("ai_completion_empty finish_reason=\(finishReason) model=\(responseModel)")
        }
    }

    // MARK: - Helpers

    /// Sorted keys keep a replayed transcript identical from one request to the
    /// next, which thinking replay depends on.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func encodeArguments(_ input: OpenAIJSONValue?) -> String {
        guard let input,
              let data = try? encoder.encode(input),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func textBlock(_ text: String) -> OpenAIJSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    private static func isThinkingBlock(_ block: OpenAIJSONValue) -> Bool {
        guard case let .object(fields) = block else { return false }
        return fields["type"] == .string("thinking") || fields["type"] == .string("redacted_thinking")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

extension OpenAIMessage {
    /// This message minus the thinking blocks `AnthropicChatClient` stashed on
    /// it, for an OpenAI-compatible provider that would not know what to do
    /// with them. OpenRouter's own `reasoning_details` entries are kept.
    var withoutAnthropicReasoning: OpenAIMessage {
        guard let details = reasoningDetails else { return self }
        let kept = details.filter { entry in
            guard case let .object(fields) = entry else { return true }
            return fields["type"] != .string(AnthropicChatClient.reasoningMarkerType)
        }
        guard kept.count != details.count else { return self }
        var copy = self
        copy.reasoningDetails = kept.isEmpty ? nil : kept
        return copy
    }
}
