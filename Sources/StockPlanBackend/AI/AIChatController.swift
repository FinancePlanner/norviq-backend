import Foundation
import Vapor

/// The in-app assistant chat endpoint. First-party sessions only (MCP tokens are
/// rejected), Pro-gated, and bounded by the same daily cap as insight cards.
/// Responds as Server-Sent Events: `tool` activity events followed by a final
/// `message` event, then `done`.
struct AIChatController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.post("ai", "chat", use: chat)
    }

    func chat(req: Request) async throws -> Response {
        // First-party only: an MCP scoped token must not reach the assistant.
        guard req.auth.get(ScopeContext.self) == nil else {
            throw Abort(.forbidden, reason: "The assistant is only available in the Norviq app.")
        }
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.aiInsights, userId: session.userId, on: req.db)
        try await enforceDailyCap(req, userId: session.userId)

        let payload = try req.content.decode(AIChatRequest.self)
        let history = payload.messages.prefix(30).map { OpenAIMessage(role: $0.sanitizedRole, content: $0.content) }
        guard history.contains(where: { $0.role == "user" }) else {
            throw Abort(.badRequest, reason: "At least one user message is required.")
        }

        let collector = ChatEventCollector()
        do {
            try await req.application.aiChatService.stream(
                history: Array(history), userId: session.userId,
                onEvent: { event in await collector.append(event) }, on: req
            )
        } catch {
            await collector.append(.message("Sorry — I couldn't complete that just now. Please try again."))
            req.logger.error("ai_chat error userId=\(session.userId) error=\(String(reflecting: error).prefix(300))")
        }

        let sse = await Self.encodeSSE(collector.events())
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        res.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        res.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        res.body = .init(string: sse)
        return res
    }

    // MARK: - SSE encoding

    static func encodeSSE(_ events: [AIChatEvent]) -> String {
        var out = ""
        for event in events {
            switch event {
            case let .toolActivity(label):
                out += sseFrame(event: "tool", data: ["label": label])
            case let .message(text):
                out += sseFrame(event: "message", data: ["content": text])
            }
        }
        out += sseFrame(event: "done", data: [:])
        return out
    }

    private static func sseFrame(event: String, data: [String: String]) -> String {
        let encoded = (try? JSONEncoder().encode(data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "event: \(event)\ndata: \(encoded)\n\n"
    }

    // MARK: - Daily cap (mirrors AIInsightsController)

    private func enforceDailyCap(_ req: Request, userId: UUID) async throws {
        let limit = Environment.get("AI_DAILY_LIMIT").flatMap(Int.init) ?? 50
        guard req.application.redis.configuration != nil else {
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "The assistant is temporarily unavailable.")
            }
            return
        }
        let day = ISO8601DateFormatter.dayBucket(Date())
        let key = RedisKey("ai_daily:\(userId.uuidString):\(day)")
        let count: Int
        do {
            count = try await req.redis.increment(key).get()
            if count == 1 {
                _ = try await req.redis.expire(key, after: .seconds(86400)).get()
            }
        } catch {
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "The assistant is temporarily unavailable.")
            }
            return
        }
        guard count <= limit else {
            throw Abort(.tooManyRequests, reason: "Daily assistant limit reached. Try again tomorrow.")
        }
    }
}

/// Serializes chat events from the (sequential) tool loop.
actor ChatEventCollector {
    private var stored: [AIChatEvent] = []
    func append(_ event: AIChatEvent) {
        stored.append(event)
    }

    func events() -> [AIChatEvent] {
        stored
    }
}

struct AIChatRequest: Content {
    let messages: [AIChatMessageInput]
}

struct AIChatMessageInput: Content {
    let role: String
    let content: String

    /// Only user/assistant roles are accepted from the client; anything else is
    /// treated as a user turn so a client cannot inject a system prompt.
    var sanitizedRole: String {
        role == "assistant" ? "assistant" : "user"
    }
}
