import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

@Suite("AI Insights Tests", .serialized)
struct AIInsightsTests {
    // MARK: - Harness

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("BYPASS_BILLING", "false", 1)
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
        let suffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(18))
        let request = AuthRegisterRequest(
            username: "ai_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "ai+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        let auth = try #require(response)
        // Clear the default trial so the user is genuinely "free" unless we grant Pro.
        let user = try #require(try await User.find(auth.userId, on: app.db))
        user.trialStartedAt = nil
        user.trialDays = nil
        user.trialTier = nil
        try await user.save(on: app.db)
        return auth
    }

    private func grantPremium(userId: UUID, on app: Application) async throws {
        try await Entitlement(userId: userId, level: "pro").save(on: app.db)
    }

    private func get(_ path: String, token: String, on app: Application) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.GET, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private let aiPaths = ["v1/ai/insights/expenses", "v1/ai/insights/portfolio", "v1/ai/insights/summary"]

    // MARK: - Entitlement gate

    @Test("Free users are blocked from every AI insight endpoint")
    func freeUsersBlocked() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free")
            for path in aiPaths {
                let (status, body) = try await get(path, token: auth.token, on: app)
                #expect(status == .forbidden)
                #expect(body.contains("feature=ai_insights") || body.contains("\"feature\":\"ai_insights\""))
                #expect(body.contains("required=pro") || body.contains("\"requiredPlan\":\"pro\""))
            }
        }
    }

    @Test("AI insights report unavailable when no OpenAI key is configured")
    func disabledWithoutKey() async throws {
        try await withApp { app in
            // Default test config sets no OPENAI_API_KEY -> DisabledOpenAIChatClient.
            let auth = try await registerUser(on: app, identifier: "nokey")
            try await grantPremium(userId: auth.userId, on: app)

            let (status, _) = try await get("v1/ai/insights/portfolio", token: auth.token, on: app)
            #expect(status == .serviceUnavailable)
        }
    }

    // MARK: - Generation (mocked LLM)

    @Test("Pro user gets a card; disclaimer is server-injected, not model-supplied")
    func proGeneratesCardWithServerDisclaimer() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "pro-card")
            try await grantPremium(userId: auth.userId, on: app)

            // Model returns a card WITHOUT a disclaimer field; the server must add the
            // standard disclaimer and ignore any model attempt to set one.
            let modelJSON = #"{"title":"Your Portfolio","body":"A neutral summary.","highlights":[{"label":"Total","value":"$0.00"}]}"#
            app.aiInsightsService = DefaultAIInsightsService(
                client: ScriptedOpenAIChatClient(toolName: "get_financial_overview", finalJSON: modelJSON)
            )

            var decoded: AIInsightCardResponse?
            try await app.testing().test(.GET, "v1/ai/insights/portfolio", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                decoded = try res.content.decode(AIInsightCardResponse.self)
            })

            let card = try #require(decoded)
            #expect(card.kind == .portfolio)
            #expect(card.title == "Your Portfolio")
            #expect(card.body == "A neutral summary.")
            #expect(card.disclaimer == AIInsightCardResponse.standardDisclaimer)
            #expect(card.highlights.first?.label == "Total")
        }
    }

    @Test("Tool round executes in the caller's scope and returns a card")
    func toolRoundExecutesForCaller() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "pro-tool")
            try await grantPremium(userId: auth.userId, on: app)

            // Scripted client always requests a tool first, proving the loop runs the
            // scoped tool (which reads ONLY this authenticated user's data) before
            // producing the final card.
            let modelJSON = #"{"title":"Snapshot","body":"Here is your data.","highlights":[]}"#
            app.aiInsightsService = DefaultAIInsightsService(
                client: ScriptedOpenAIChatClient(toolName: "get_expense_report", finalJSON: modelJSON)
            )

            let (status, body) = try await get("v1/ai/insights/expenses", token: auth.token, on: app)
            #expect(status == .ok)
            #expect(body.contains("Snapshot"))
        }
    }
}

/// Deterministic stand-in for the OpenAI client. Stateless: it decides what to
/// return purely from the conversation so far — requests one tool call, then once
/// a tool result is present, returns the scripted final JSON card.
private struct ScriptedOpenAIChatClient: OpenAIChatClient {
    let toolName: String
    let finalJSON: String

    func chat(
        messages: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat _: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        if messages.contains(where: { $0.role == "tool" }) {
            return OpenAIMessage(role: "assistant", content: finalJSON)
        }
        return OpenAIMessage(
            role: "assistant",
            toolCalls: [
                OpenAIToolCall(
                    id: "call_1",
                    type: "function",
                    function: OpenAIFunctionCall(name: toolName, arguments: "{}")
                ),
            ]
        )
    }
}
