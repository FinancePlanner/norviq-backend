import Foundation
import NIOConcurrencyHelpers
import NIOCore
@testable import StockPlanBackend
import Testing
import Vapor

/// Stands in for `req.client`: records every request and answers from a script.
/// The last scripted reply repeats once the script runs out.
final class AnthropicStubHTTP: @unchecked Sendable {
    private let lock = NIOLock()
    private var replies: [(HTTPStatus, String)]
    private var recorded: [ClientRequest] = []

    init(_ replies: [(HTTPStatus, String)]) {
        self.replies = replies
    }

    func reply(to request: ClientRequest) -> (HTTPStatus, String) {
        lock.withLock {
            recorded.append(request)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    var requests: [ClientRequest] {
        lock.withLock { recorded }
    }

    /// The JSON bodies sent, decoded loosely for inspection.
    var bodies: [[String: Any]] {
        requests.compactMap { request in
            guard let buffer = request.body,
                  let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    var rawBodies: [String] {
        requests.compactMap { $0.body.map { String(buffer: $0) } }
    }

    struct Client: Vapor.Client {
        let stub: AnthropicStubHTTP
        let eventLoop: any EventLoop

        func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
            let (status, body) = stub.reply(to: request)
            var headers = HTTPHeaders()
            headers.contentType = .json
            return eventLoop.makeSucceededFuture(
                ClientResponse(status: status, headers: headers, body: ByteBuffer(string: body))
            )
        }

        func delegating(to eventLoop: any EventLoop) -> any Vapor.Client {
            Client(stub: stub, eventLoop: eventLoop)
        }
    }

    /// Runs `test` with a request whose outbound client is this stub.
    func withRequest(_ test: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.clients.use { app in Client(stub: self, eventLoop: app.eventLoopGroup.next()) }
        do {
            try await test(Request(application: app, on: app.eventLoopGroup.next()))
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

/// A Messages API response body.
func anthropicReply(
    content: String,
    stopReason: String = "end_turn",
    usage: String = #"{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
) -> String {
    #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","content":\#(content),"stop_reason":"\#(stopReason)","usage":\#(usage)}"#
}

private let thinkingBlock: OpenAIJSONValue = .object([
    "type": .string("thinking"),
    "thinking": .string(""),
    "signature": .string("sig-abc"),
])

/// An assistant tool turn exactly as `AnthropicChatClient` hands one back.
private func anthropicToolTurn(id: String = "toolu_1", name: String = "list_expenses") -> OpenAIMessage {
    let marker: OpenAIJSONValue = .object([
        "type": .string(AnthropicChatClient.reasoningMarkerType),
        "blocks": .array([thinkingBlock]),
    ])
    return OpenAIMessage(
        role: "assistant",
        content: nil,
        toolCalls: [OpenAIToolCall(id: id, type: "function", function: OpenAIFunctionCall(name: name, arguments: #"{"month":"2026-08"}"#))],
        reasoningDetails: [marker]
    )
}

private let sampleTool = OpenAITool(function: OpenAIFunctionDef(
    name: "list_expenses",
    description: "Lists expenses for a month.",
    parameters: OpenAIJSONSchema(
        properties: ["month": OpenAIParameter(type: "string", description: "YYYY-MM")],
        required: ["month"]
    )
))

private func request(
    _ messages: [OpenAIMessage],
    tools: [OpenAITool] = [],
    responseFormat: String? = nil,
    maxTokens: Int = 4096,
    options: AnthropicMessagesOptions = AnthropicMessagesOptions()
) -> AnthropicMessagesRequest {
    AnthropicChatClient.makeRequest(
        messages: messages,
        tools: tools,
        responseFormat: responseFormat,
        model: "claude-haiku-5-5",
        maxTokens: maxTokens,
        options: options
    )
}

private func blockTypes(_ turn: AnthropicTurn) -> [String] {
    turn.content.map { block in
        guard case let .object(fields) = block, case let .string(type) = fields["type"] else { return "?" }
        return type
    }
}

private func field(_ block: OpenAIJSONValue, _ key: String) -> OpenAIJSONValue? {
    guard case let .object(fields) = block else { return nil }
    return fields[key]
}

private func encoded(_ body: AnthropicMessagesRequest) throws -> String {
    try String(bytes: JSONEncoder().encode(body), encoding: .utf8) ?? ""
}

private func decodeReply(_ json: String) throws -> AnthropicMessagesResponse {
    try JSONDecoder().decode(AnthropicMessagesResponse.self, from: Data(json.utf8))
}

@Suite("Anthropic chat client")
struct AnthropicChatClientTests {
    // MARK: - Request translation

    @Test("System messages are joined into the top-level system prompt")
    func systemMessagesJoin() {
        let body = request([
            OpenAIMessage(role: "system", content: "You are Norviq."),
            OpenAIMessage(role: "user", content: "Hi"),
            OpenAIMessage(role: "system", content: "Be brief."),
        ])

        #expect(body.system == "You are Norviq.\n\nBe brief.")
        #expect(body.messages.map(\.role) == ["user"])
    }

    @Test("A json_object request adds the JSON instruction to the system prompt")
    func jsonObjectAddsSystemLine() {
        let body = request(
            [OpenAIMessage(role: "system", content: "Summarise."), OpenAIMessage(role: "user", content: "Data")],
            responseFormat: "json_object"
        )
        #expect(body.system == "Summarise.\n\n\(AnthropicChatClient.jsonInstruction)")
    }

    @Test("No sampling parameters are ever sent, and tools carry an input_schema with tool_choice auto")
    func noSamplingParameters() throws {
        let body = request([OpenAIMessage(role: "user", content: "Spend?")], tools: [sampleTool])
        let json = try encoded(body)

        #expect(!json.contains("temperature"))
        #expect(!json.contains("top_p"))
        #expect(!json.contains("top_k"))
        #expect(json.contains(#""input_schema""#))
        #expect(json.contains(#""max_tokens":4096"#))
        #expect(body.toolChoice == .object(["type": .string("auto")]))
        #expect(body.tools?.first?.name == "list_expenses")
    }

    @Test("Assistant tool calls become tool_use blocks with parsed input; bad JSON is wrapped")
    func toolCallsBecomeToolUse() {
        let body = request([
            OpenAIMessage(role: "user", content: "Spend?"),
            OpenAIMessage(role: "assistant", content: "Checking.", toolCalls: [
                OpenAIToolCall(id: "a", type: "function", function: OpenAIFunctionCall(name: "list_expenses", arguments: #"{"month":"2026-08"}"#)),
                OpenAIToolCall(id: "b", type: "function", function: OpenAIFunctionCall(name: "list_goals", arguments: "not json")),
                OpenAIToolCall(id: "c", type: "function", function: OpenAIFunctionCall(name: "summary", arguments: "")),
            ]),
            OpenAIMessage(role: "tool", content: "[]", toolCallId: "a", name: "list_expenses"),
            OpenAIMessage(role: "tool", content: "[]", toolCallId: "b", name: "list_goals"),
            OpenAIMessage(role: "tool", content: "{}", toolCallId: "c", name: "summary"),
        ], tools: [sampleTool], options: AnthropicMessagesOptions(thinkingEnabled: false))

        let assistant = body.messages[1]
        #expect(blockTypes(assistant) == ["text", "tool_use", "tool_use", "tool_use"])
        #expect(field(assistant.content[1], "input") == .object(["month": .string("2026-08")]))
        #expect(field(assistant.content[2], "input") == .object(["_raw": .string("not json")]))
        #expect(field(assistant.content[3], "input") == .object([:]))
    }

    @Test("Consecutive tool results become one user turn, with a following user message merged in after them")
    func toolResultsMerge() {
        let body = request([
            OpenAIMessage(role: "user", content: "Spend?"),
            anthropicToolTurn(),
            OpenAIMessage(role: "tool", content: "[1]", toolCallId: "toolu_1", name: "list_expenses"),
            OpenAIMessage(role: "tool", content: "[2]", toolCallId: "toolu_2", name: "list_goals"),
            OpenAIMessage(role: "user", content: "Answer now."),
        ], tools: [sampleTool])

        #expect(body.messages.map(\.role) == ["user", "assistant", "user"])
        let results = body.messages[2]
        #expect(blockTypes(results) == ["tool_result", "tool_result", "text"])
        #expect(field(results.content[0], "tool_use_id") == .string("toolu_1"))
        #expect(field(results.content[1], "content") == .string("[2]"))
    }

    @Test("Same-role turns merge and empty text is dropped")
    func sameRoleMergeAndEmptyDropped() {
        let body = request([
            OpenAIMessage(role: "user", content: "First"),
            OpenAIMessage(role: "user", content: "   "),
            OpenAIMessage(role: "user", content: "Second"),
            OpenAIMessage(role: "assistant", content: ""),
            OpenAIMessage(role: "assistant", content: "Reply"),
            OpenAIMessage(role: "user", content: "Third"),
        ])

        #expect(body.messages.map(\.role) == ["user", "assistant", "user"])
        #expect(blockTypes(body.messages[0]) == ["text", "text"])
        #expect(body.messages[1].content.count == 1)
    }

    @Test("A transcript ending on the assistant gets a user turn, because prefill is a 400")
    func endsOnUser() {
        let body = request([
            OpenAIMessage(role: "user", content: "Hi"),
            OpenAIMessage(role: "assistant", content: "Hello"),
        ])

        #expect(body.messages.last?.role == "user")
        #expect(body.messages.last?.content == [.object(["type": .string("text"), "text": .string("Continue.")])])
    }

    @Test("The tool-free final call flattens tool turns to text and drops thinking")
    func finalCallFlattensToolTurns() throws {
        let body = request([
            OpenAIMessage(role: "user", content: "Spend?"),
            anthropicToolTurn(),
            OpenAIMessage(role: "tool", content: "[1]", toolCallId: "toolu_1", name: "list_expenses"),
            OpenAIMessage(role: "user", content: "Give the final answer now."),
        ])
        let json = try encoded(body)

        #expect(body.tools == nil)
        #expect(body.toolChoice == nil)
        #expect(!json.contains("tool_use"))
        #expect(!json.contains("tool_result"))
        #expect(!json.contains("sig-abc"))
        #expect(body.messages.map(\.role) == ["user", "assistant", "user"])
        #expect(blockTypes(body.messages[1]) == ["text"])
        #expect(blockTypes(body.messages[2]) == ["text", "text"])
    }

    // MARK: - Thinking

    @Test("Thinking blocks are replayed unchanged before the turn's tool_use blocks")
    func thinkingReplay() {
        let body = request([
            OpenAIMessage(role: "user", content: "Spend?"),
            anthropicToolTurn(),
            OpenAIMessage(role: "tool", content: "[1]", toolCallId: "toolu_1", name: "list_expenses"),
        ], tools: [sampleTool])

        #expect(body.thinking == AnthropicChatClient.thinkingAdaptive)
        #expect(blockTypes(body.messages[1]) == ["thinking", "tool_use"])
        #expect(body.messages[1].content[0] == thinkingBlock)
    }

    @Test("A response round-trips into the next request with its thinking intact")
    func responseRoundTrip() throws {
        let reply = try decodeReply(anthropicReply(
            content: #"[{"type":"thinking","thinking":"","signature":"sig-xyz"},{"type":"redacted_thinking","data":"opaque"},{"type":"tool_use","id":"toolu_9","name":"list_expenses","input":{"month":"2026-08"}}]"#,
            stopReason: "tool_use"
        ))
        let turn = try AnthropicChatClient.translateResponse(reply, responseFormat: nil).message

        let body = request([
            OpenAIMessage(role: "user", content: "Spend?"),
            turn,
            OpenAIMessage(role: "tool", content: "[]", toolCallId: "toolu_9", name: "list_expenses"),
        ], tools: [sampleTool])

        #expect(body.thinkingEnabled)
        #expect(blockTypes(body.messages[1]) == ["thinking", "redacted_thinking", "tool_use"])
        #expect(body.messages[1].content[0] == reply.content[0])
        #expect(body.messages[1].content[1] == reply.content[1])
    }

    @Test("A tool turn another rung produced switches thinking off and sends no thinking blocks")
    func foreignToolTurnDisablesThinking() throws {
        let openRouterTurn = OpenAIMessage(
            role: "assistant",
            toolCalls: [OpenAIToolCall(id: "call_1", type: "function", function: OpenAIFunctionCall(name: "list_expenses", arguments: "{}"))],
            reasoningDetails: [.object(["type": .string("reasoning.text"), "text": .string("hmm")])]
        )
        let body = request([
            OpenAIMessage(role: "user", content: "Spend?"),
            anthropicToolTurn(),
            OpenAIMessage(role: "tool", content: "[1]", toolCallId: "toolu_1", name: "list_expenses"),
            openRouterTurn,
            OpenAIMessage(role: "tool", content: "[2]", toolCallId: "call_1", name: "list_expenses"),
        ], tools: [sampleTool])

        #expect(body.thinking == AnthropicChatClient.thinkingDisabled)
        #expect(try !encoded(body).contains("sig-abc"))
        #expect(try !encoded(body).contains("reasoning.text"))
    }

    @Test("ANTHROPIC_THINKING=disabled and a max_tokens under 1024 both switch thinking off")
    func thinkingSwitches() {
        let messages = [OpenAIMessage(role: "user", content: "Hi")]
        #expect(request(messages).thinking == AnthropicChatClient.thinkingAdaptive)
        #expect(request(messages, options: AnthropicMessagesOptions(thinkingEnabled: false)).thinking
            == AnthropicChatClient.thinkingDisabled)
        #expect(request(messages, maxTokens: 1023).thinking == AnthropicChatClient.thinkingDisabled)
        #expect(request(messages, maxTokens: 1024).thinking == AnthropicChatClient.thinkingAdaptive)
    }

    @Test("Effort is omitted unless configured, and capped at high when thinking is off")
    func effort() throws {
        let messages = [OpenAIMessage(role: "user", content: "Hi")]
        #expect(request(messages).outputConfig == nil)
        #expect(try !encoded(request(messages)).contains("output_config"))
        #expect(request(messages, options: AnthropicMessagesOptions(effort: "low")).outputConfig?.effort == "low")
        #expect(request(messages, options: AnthropicMessagesOptions(effort: "max")).outputConfig?.effort == "max")
        #expect(request(messages, options: AnthropicMessagesOptions(effort: "max", thinkingEnabled: false))
            .outputConfig?.effort == "high")
    }

    // MARK: - Response translation

    @Test("Text, tool_use and thinking blocks map onto the OpenAI message")
    func responseMapping() throws {
        let reply = try decodeReply(anthropicReply(
            content: #"[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"Checking "},{"type":"text","text":"now."},{"type":"tool_use","id":"toolu_1","name":"list_expenses","input":{"month":"2026-08"}}]"#,
            stopReason: "tool_use"
        ))
        let completion = try AnthropicChatClient.translateResponse(reply, responseFormat: nil)

        #expect(completion.finishReason == "tool_calls")
        #expect(completion.message.content == "Checking now.")
        #expect(completion.message.toolCalls?.first?.id == "toolu_1")
        #expect(completion.message.toolCalls?.first?.function.arguments == #"{"month":"2026-08"}"#)
        #expect(AnthropicChatClient.thinkingBlocks(in: completion.message)?.count == 1)
    }

    @Test("A refusal throws so the chain fails over")
    func refusalThrows() throws {
        let reply = try decodeReply(anthropicReply(content: "[]", stopReason: "refusal"))
        #expect(throws: OpenAIChatUpstreamError.self) {
            try AnthropicChatClient.translateResponse(reply, responseFormat: nil)
        }
    }

    @Test("max_tokens maps to finish length and drops a half-written tool call")
    func maxTokensIsLength() throws {
        let reply = try decodeReply(anthropicReply(
            content: #"[{"type":"text","text":"Your biggest"},{"type":"tool_use","id":"t","name":"x","input":{}}]"#,
            stopReason: "max_tokens"
        ))
        let completion = try AnthropicChatClient.translateResponse(reply, responseFormat: nil)

        #expect(completion.finishReason == "length")
        #expect(completion.message.toolCalls == nil)
        #expect(DefaultOpenAIChatClient.canResume(
            finishReason: completion.finishReason, message: completion.message, responseFormat: nil
        ))
    }

    @Test("max_tokens with nothing but thinking is unusable, so the chain demotes")
    func maxTokensThinkingOnlyIsUnusable() throws {
        let reply = try decodeReply(anthropicReply(
            content: #"[{"type":"thinking","thinking":"","signature":"s"}]"#,
            stopReason: "max_tokens"
        ))
        let completion = try AnthropicChatClient.translateResponse(reply, responseFormat: nil)
        #expect(completion.message.hasNoUsableOutput)
    }

    @Test("A JSON reply is cut out of code fences and surrounding prose")
    func jsonFenceStrip() throws {
        #expect(AnthropicChatClient.extractJSONObject("```json\n{\"a\":1}\n```") == #"{"a":1}"#)
        #expect(AnthropicChatClient.extractJSONObject("```\n{\"a\":{\"b\":2}}\n```\n") == #"{"a":{"b":2}}"#)
        #expect(AnthropicChatClient.extractJSONObject("Here it is: {\"a\":1} Hope that helps.") == #"{"a":1}"#)
        #expect(AnthropicChatClient.extractJSONObject(#"{"a":1}"#) == #"{"a":1}"#)

        let reply = try decodeReply(anthropicReply(content: #"[{"type":"text","text":"```json\n{\"insights\":[]}\n```"}]"#))
        let completion = try AnthropicChatClient.translateResponse(reply, responseFormat: "json_object")
        #expect(completion.message.content == #"{"insights":[]}"#)
    }

    // MARK: - Errors and metering

    @Test("A spent usage limit is classed as out of credits; other statuses pass through")
    func statusClassification() {
        let limit = #"{"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API usage limits."}}"#
        let credit = #"{"type":"error","error":{"message":"Your credit balance is too low to access the Anthropic API."}}"#
        #expect(AnthropicChatClient.upstreamStatus(httpStatus: 400, body: limit) == 402)
        #expect(AnthropicChatClient.upstreamStatus(httpStatus: 400, body: credit) == 402)
        #expect(AnthropicChatClient.upstreamStatus(httpStatus: 400, body: #"{"error":{"message":"bad"}}"#) == 400)
        #expect(AnthropicChatClient.upstreamStatus(httpStatus: 401, body: "") == 401)
        #expect(AnthropicChatClient.upstreamStatus(httpStatus: 529, body: "") == 529)
    }

    @Test("Estimated cost uses $0.10/$0.50 per MTok, five times over 100K prompt tokens")
    func costEstimate() {
        #expect(AnthropicChatClient.estimatedCostMicros(
            inputTokens: 1000, outputTokens: 1000, cacheReadTokens: 0, cacheCreationTokens: 0
        ) == 600)
        #expect(AnthropicChatClient.estimatedCostMicros(
            inputTokens: 200_000, outputTokens: 1000, cacheReadTokens: 0, cacheCreationTokens: 0
        ) == (20000 + 500) * 5)
    }

    @Test("Only this client's marker is stripped for OpenAI-compatible providers")
    func stripKeepsOpenRouterDetails() {
        let openRouter: OpenAIJSONValue = .object(["type": .string("reasoning.encrypted"), "data": .string("x")])
        var turn = anthropicToolTurn()
        turn.reasoningDetails?.append(openRouter)

        #expect(turn.withoutAnthropicReasoning.reasoningDetails == [openRouter])
        #expect(anthropicToolTurn().withoutAnthropicReasoning.reasoningDetails == nil)
    }

    // MARK: - Over the (stubbed) wire

    @Test("chat posts to /v1/messages with the Anthropic headers and no sampling parameters")
    func wireRequest() async throws {
        let stub = AnthropicStubHTTP([(.ok, anthropicReply(content: #"[{"type":"text","text":"Hello"}]"#))])
        try await stub.withRequest { req in
            let client = AnthropicChatClient(
                apiKey: "sk-ant-test", model: "claude-haiku-5-5", baseURL: "https://anthropic.test", maxTokens: 4096,
                options: AnthropicMessagesOptions(effort: "low")
            )
            let message = try await client.chat(
                messages: [OpenAIMessage(role: "system", content: "S"), OpenAIMessage(role: "user", content: "Hi")],
                tools: [], responseFormat: nil, on: req
            )

            #expect(message.content == "Hello")
            let sent = try #require(stub.requests.first)
            #expect(sent.url.string == "https://anthropic.test/v1/messages")
            #expect(sent.headers.first(name: "x-api-key") == "sk-ant-test")
            #expect(sent.headers.first(name: "anthropic-version") == "2023-06-01")
            #expect(sent.headers.contentType == .json)
            let body = try #require(stub.bodies.first)
            #expect(body["temperature"] == nil)
            #expect(body["system"] as? String == "S")
            #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        }
    }

    @Test("A non-2xx throws OpenAIChatUpstreamError with the status")
    func non2xxThrows() async throws {
        let stub = AnthropicStubHTTP([(.serviceUnavailable, #"{"type":"error","error":{"type":"overloaded_error"}}"#)])
        try await stub.withRequest { req in
            let client = AnthropicChatClient(apiKey: "k", model: "claude-haiku-5-5", baseURL: "https://anthropic.test", maxTokens: 4096)
            do {
                _ = try await client.chat(messages: [OpenAIMessage(role: "user", content: "Hi")], tools: [], responseFormat: nil, on: req)
                Issue.record("expected a throw")
            } catch let error as OpenAIChatUpstreamError {
                #expect(error.upstreamStatus == 503)
            }
        }
    }

    @Test("A truncated answer is resumed and stitched, and its thinking marker dropped")
    func truncationResumes() async throws {
        let stub = AnthropicStubHTTP([
            (.ok, anthropicReply(content: #"[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"Your biggest category"}]"#, stopReason: "max_tokens")),
            (.ok, anthropicReply(content: #"[{"type":"text","text":" was rent."}]"#)),
        ])
        try await stub.withRequest { req in
            let client = AnthropicChatClient(apiKey: "k", model: "claude-haiku-5-5", baseURL: "https://anthropic.test", maxTokens: 4096)
            let message = try await client.chat(
                messages: [OpenAIMessage(role: "user", content: "Biggest category?")],
                tools: [], responseFormat: nil, on: req
            )

            #expect(message.content == "Your biggest category was rent.")
            #expect(message.reasoningDetails == nil)
            #expect(stub.requests.count == 2)
            // The resume request replays the truncated turn, then asks for the rest.
            let roles = (stub.bodies.last?["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }
            #expect(roles == ["user", "assistant", "user"])
        }
    }

    @Test("The OpenAI-compatible client keeps Anthropic thinking off its wire")
    func openAIClientStripsMarker() async throws {
        let stub = AnthropicStubHTTP([(.ok, #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}]}"#)])
        try await stub.withRequest { req in
            let client = DefaultOpenAIChatClient(apiKey: "k", model: "m", baseURL: "https://openrouter.test/api/v1", maxTokens: 700)
            _ = try await client.chat(
                messages: [
                    OpenAIMessage(role: "user", content: "Spend?"),
                    anthropicToolTurn(),
                    OpenAIMessage(role: "tool", content: "[]", toolCallId: "toolu_1", name: "list_expenses"),
                ],
                tools: [sampleTool], responseFormat: nil, on: req
            )

            let raw = try #require(stub.rawBodies.first)
            #expect(!raw.contains(AnthropicChatClient.reasoningMarkerType))
            #expect(!raw.contains("sig-abc"))
            #expect(raw.contains("toolu_1"))
        }
    }
}
