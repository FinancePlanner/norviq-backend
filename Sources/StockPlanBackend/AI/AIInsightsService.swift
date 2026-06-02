import Foundation
import StockPlanShared
import Vapor

protocol AIInsightsService: Sendable {
    func generate(kind: AIInsightKind, userId: UUID, on req: Request) async throws -> AIInsightCardResponse
}

struct DefaultAIInsightsService: AIInsightsService {
    let client: any OpenAIChatClient
    /// Safety cap on tool round-trips per generation, bounding cost + latency.
    var maxToolRounds: Int = 4

    func generate(kind: AIInsightKind, userId: UUID, on req: Request) async throws -> AIInsightCardResponse {
        let context = AIToolContext(userId: userId)
        let tools = AIToolRegistry.toolDefinitions()

        var messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system", content: AIPrompt.system),
            OpenAIMessage(role: "user", content: AIPrompt.userPrompt(for: kind)),
        ]

        for _ in 0 ..< maxToolRounds {
            let message = try await client.chat(
                messages: messages,
                tools: tools,
                responseFormat: "json_object",
                on: req
            )

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                // Record the assistant turn that requested the calls, then answer each.
                messages.append(message)
                for call in toolCalls {
                    let result = try await AIToolRegistry.execute(
                        name: call.function.name, context: context, on: req
                    )
                    messages.append(OpenAIMessage(
                        role: "tool",
                        content: result,
                        toolCallId: call.id,
                        name: call.function.name
                    ))
                }
                continue
            }

            // No tool calls — this is the final answer.
            return try Self.parseCard(message.content, kind: kind)
        }

        // Tool budget exhausted: force a final, tool-free JSON answer.
        messages.append(OpenAIMessage(role: "user", content: AIPrompt.finalizeInstruction))
        let final = try await client.chat(
            messages: messages, tools: [], responseFormat: "json_object", on: req
        )
        return try Self.parseCard(final.content, kind: kind)
    }

    /// Model output for a card. `id`, `kind`, `disclaimer`, and `generatedAt` are
    /// server-controlled and intentionally NOT read from the model.
    private struct AICardPayload: Content {
        var title: String
        var body: String
        var highlights: [AIInsightHighlight]?
    }

    static func parseCard(_ json: String?, kind: AIInsightKind) throws -> AIInsightCardResponse {
        guard let json, let data = json.data(using: .utf8) else {
            throw Abort(.badGateway, reason: "AI returned an empty response.")
        }
        let payload: AICardPayload
        do {
            payload = try JSONDecoder().decode(AICardPayload.self, from: data)
        } catch {
            throw Abort(.badGateway, reason: "AI returned an invalid response.")
        }
        return AIInsightCardResponse(
            kind: kind,
            title: payload.title,
            body: payload.body,
            highlights: payload.highlights ?? []
        )
    }
}
