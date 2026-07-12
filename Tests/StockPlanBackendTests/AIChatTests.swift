import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("AI Chat Assistant Tests", .serialized)
struct AIChatTests {
    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            // Ensure the entitlement gate is active (ambient env may set BYPASS_BILLING=true).
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

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "chat_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "chat_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    private func grantPro(app: Application, userId: UUID) async throws {
        try await Entitlement(userId: userId, level: "pro").save(on: app.db)
    }

    private func chatBody(_ text: String) -> AIChatRequest {
        AIChatRequest(messages: [AIChatMessageInput(role: "user", content: text)])
    }

    @Test("Chat streams tool activity then a final message as SSE")
    func chatStreamsSSE() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await grantPro(app: app, userId: user.userId)
            app.aiChatService = DefaultAIChatService(
                client: ScriptedChatClient(toolName: "get_financial_overview", finalText: "Here is your overview.")
            )
            try await app.testing().test(.POST, "v1/ai/chat", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(chatBody("How am I doing?"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType)?.contains("text/event-stream") == true)
                let body = res.body.string
                #expect(body.contains("event: tool"))
                #expect(body.contains("event: message"))
                #expect(body.contains("Here is your overview."))
                #expect(body.contains("event: done"))
            })
        }
    }

    @Test("delete_expense does not delete until confirmed")
    func deleteRequiresConfirmation() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await grantPro(app: app, userId: user.userId)

            // Seed an expense.
            var expenseId = ""
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(ExpenseRequest(title: "Coffee", amount: 4, pillar: .fundamentals, occurredOn: "2026-07-02"))
            }, afterResponse: { res async throws in
                expenseId = try res.content.decode(ExpenseResponse.self).id
            })

            // Model calls delete WITHOUT confirm → tool returns needs_confirmation, no delete.
            app.aiChatService = DefaultAIChatService(
                client: ScriptedChatClient(
                    toolName: "delete_expense",
                    toolArgs: #"{"id":"\#(expenseId)"}"#,
                    finalText: "Please confirm you want to delete Coffee."
                )
            )
            try await app.testing().test(.POST, "v1/ai/chat", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(chatBody("Delete my coffee expense"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            // Expense still exists.
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                let items = try res.content.decode([ExpenseResponse].self)
                #expect(items.contains { $0.id == expenseId })
            })
        }
    }

    @Test("Free user is upgrade-gated")
    func freeUserGated() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            // Registration grants a default trial (Pro-equivalent). Clear it so the
            // user is genuinely free and the entitlement gate applies.
            if let dbUser = try await User.find(user.userId, on: app.db) {
                dbUser.trialStartedAt = nil
                dbUser.trialDays = nil
                dbUser.trialTier = nil
                try await dbUser.save(on: app.db)
            }
            app.aiChatService = DefaultAIChatService(client: ScriptedChatClient(toolName: nil, finalText: "hi"))
            try await app.testing().test(.POST, "v1/ai/chat", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(chatBody("hello"))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }
}

/// A scripted assistant client: on the first turn it optionally calls one tool,
/// then returns the final text once it sees a tool result (or immediately if no tool).
private struct ScriptedChatClient: OpenAIChatClient {
    let toolName: String?
    var toolArgs: String = "{}"
    let finalText: String

    func chat(
        messages: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat _: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        guard let toolName else {
            return OpenAIMessage(role: "assistant", content: finalText)
        }
        if messages.contains(where: { $0.role == "tool" }) {
            return OpenAIMessage(role: "assistant", content: finalText)
        }
        return OpenAIMessage(
            role: "assistant",
            toolCalls: [OpenAIToolCall(id: "call_1", type: "function",
                                       function: OpenAIFunctionCall(name: toolName, arguments: toolArgs))]
        )
    }
}
