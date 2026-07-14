import Fluent
import Foundation
import StockPlanShared
import Vapor

struct AIAssistantTurnService {
    private struct RequestPayload: Content {
        let model: String
        let input: String
        let tools: [Tool]
        let store: Bool
        let maxOutputTokens: Int
        enum CodingKeys: String, CodingKey {
            case model, input, tools, store
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct Tool: Codable {
        struct Parameters: Codable {
            let type = "object"
            let properties: [String: Property]
            let required: [String]
            let additionalProperties = false
        }

        struct Property: Codable {
            let type: String
            let description: String
            let enumValues: [String]?
            enum CodingKeys: String, CodingKey { case type, description; case enumValues = "enum" }
        }

        let type = "function"
        let name: String
        let description: String
        let parameters: Parameters
        let strict = true
    }

    private struct APIResponse: Content {
        struct Output: Codable {
            struct Part: Codable { let type: String?; let text: String? }
            let type: String
            let name: String?
            let arguments: String?
            let content: [Part]?
        }

        let output: [Output]
    }

    struct Result: Sendable {
        let text: String
        let pendingAction: AIPendingAction?
    }

    func generate(userId: UUID, conversation: AIConversation, userMessage: String, req: Request) async throws -> Result {
        let context = try await financialContext(userId: userId, req: req)
        let historyRows = try await AIAssistantMessage.query(on: req.db)
            .filter(\.$conversation.$id == conversation.requireID())
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .limit(20)
            .all()
            .reversed()
        let history = try historyRows.map {
            try "\($0.role): \(req.userPIIEncryptionService.decryptString($0.contentEncrypted))"
        }.joined(separator: "\n")
        let input = """
        You are Norviq's personal-finance assistant. Be concise, practical, and cautious.
        Use only supplied data. State when data is missing. Never invent transactions, holdings, or tax facts.
        Do not execute mutations yourself. For a requested expense or goal change, call exactly one provided function.
        The application will show the proposed action to the user and execute it only after explicit confirmation.

        FINANCIAL CONTEXT
        \(context)

        CONVERSATION
        \(history)
        user: \(userMessage)
        """
        let provider = AIProviderConfiguration.load()
        guard provider.isConfigured else { throw Abort(.serviceUnavailable, reason: "AI assistant is not configured.") }
        let response = try await req.client.post(URI(string: "\(provider.baseURL)/responses")) { request in
            request.headers.bearerAuthorization = .init(token: provider.apiKey)
            try request.content.encode(RequestPayload(
                model: provider.chatModel,
                input: input,
                tools: Self.tools,
                store: false,
                maxOutputTokens: 1200
            ))
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "OpenAI Responses API returned \(response.status.code).")
        }
        let envelope = try response.content.decode(APIResponse.self)
        if let call = envelope.output.first(where: { $0.type == "function_call" }),
           let name = call.name, let arguments = call.arguments,
           Self.allowedToolNames.contains(name)
        {
            let summary = summaryForAction(name: name, arguments: arguments)
            let action = AIPendingAction()
            action.userId = userId
            action.conversationId = try conversation.requireID()
            action.toolName = name
            action.argumentsEncrypted = try req.userPIIEncryptionService.encryptString(arguments)
            action.summaryEncrypted = try req.userPIIEncryptionService.encryptString(summary)
            action.status = AIActionStatus.pending.rawValue
            action.expiresAt = Date().addingTimeInterval(15 * 60)
            try await action.create(on: req.db)
            return Result(text: "Please review and confirm this action: \(summary)", pendingAction: action)
        }
        let text = envelope.output.flatMap { $0.content ?? [] }
            .first(where: { $0.type == "output_text" })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { throw Abort(.badGateway, reason: "OpenAI returned no assistant message.") }
        return Result(text: String(text.prefix(8000)), pendingAction: nil)
    }

    private func financialContext(userId: UUID, req: Request) async throws -> String {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        async let expensesTask = Expense.query(on: req.db).filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= monthStart).all()
        async let budgetTask = BudgetSnapshot.query(on: req.db).filter(\.$user.$id == userId)
            .filter(\.$monthStart == monthStart).first()
        async let stocksTask = Stock.query(on: req.db).filter(\.$userId == userId).all()
        async let goalsTask = Goal.owned(by: userId, on: req.db).all()
        let (expenses, budget, stocks, goals) = try await (expensesTask, budgetTask, stocksTask, goalsTask)
        let spent = expenses.reduce(0) { $0 + $1.amount * max(0, min(100, $1.userSharePercent)) / 100 }
        let portfolioValue = stocks.reduce(0) { $0 + ($1.shares * $1.buyPrice) }
        let openGoals = goals.count(where: { $0.status != "completed" })
        let netIncome = budget.map { String(round2($0.netSalary)) } ?? "not configured"
        return """
        Current-month expense count: \(expenses.count)
        Current-month spending: \(round2(spent))
        Current-month net income: \(netIncome)
        Portfolio position count: \(stocks.count)
        Portfolio cost-basis value: \(round2(portfolioValue))
        Open manual goals: \(openGoals)
        """
    }

    private func summaryForAction(name: String, arguments _: String) -> String {
        switch name {
        case "create_expense": "Create the proposed expense."
        case "delete_expense": "Delete the selected expense."
        case "create_goal": "Create the proposed financial goal."
        case "update_goal": "Update the selected financial goal."
        case "delete_goal": "Delete the selected financial goal."
        default: "Apply the proposed change."
        }
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static let allowedToolNames: Set<String> = [
        "create_expense", "delete_expense", "create_goal", "update_goal", "delete_goal",
    ]

    private static let tools: [Tool] = [
        Tool(name: "create_expense", description: "Propose creating an expense.", parameters: .init(properties: [
            "title": .init(type: "string", description: "Expense title", enumValues: nil),
            "amount": .init(type: "number", description: "Positive amount", enumValues: nil),
            "pillar": .init(type: "string", description: "Budget pillar", enumValues: ["fundamentals", "fun", "future"]),
            "occurred_on": .init(type: "string", description: "Date formatted YYYY-MM-DD", enumValues: nil),
        ], required: ["title", "amount", "pillar", "occurred_on"])),
        Tool(name: "delete_expense", description: "Propose deleting an expense by id.", parameters: .init(properties: [
            "id": .init(type: "string", description: "Expense UUID", enumValues: nil),
        ], required: ["id"])),
        Tool(name: "create_goal", description: "Propose creating a financial goal.", parameters: .init(properties: [
            "title": .init(type: "string", description: "Goal title", enumValues: nil),
        ], required: ["title"])),
        Tool(name: "update_goal", description: "Propose renaming a financial goal.", parameters: .init(properties: [
            "id": .init(type: "string", description: "Goal UUID", enumValues: nil),
            "title": .init(type: "string", description: "New goal title", enumValues: nil),
        ], required: ["id", "title"])),
        Tool(name: "delete_goal", description: "Propose deleting a financial goal.", parameters: .init(properties: [
            "id": .init(type: "string", description: "Goal UUID", enumValues: nil),
        ], required: ["id"])),
    ]
}

extension AIAssistantController {
    struct ChatPayload: Content { let content: String }

    @Sendable func chat(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let id = req.parameters.get("id", as: UUID.self),
              let conversation = try await AIConversation.query(on: req.db)
              .filter(\.$id == id).filter(\.$userId == userId).first()
        else { throw Abort(.notFound) }
        let content = try req.content.decode(ChatPayload.self).content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.count <= 12000 else { throw Abort(.badRequest, reason: "Message must contain 1 to 12,000 characters.") }
        try await consumeAssistantTurn(userId: userId, req: req)
        let userMessage = try AIAssistantMessage(conversationId: id, userId: userId, role: AIAssistantRole.user.rawValue,
                                                 contentEncrypted: req.userPIIEncryptionService.encryptString(content))
        try await userMessage.create(on: req.db)

        let result = try await AIAssistantTurnService().generate(userId: userId, conversation: conversation, userMessage: content, req: req)
        let assistantMessage = try AIAssistantMessage(conversationId: id, userId: userId, role: AIAssistantRole.assistant.rawValue,
                                                      contentEncrypted: req.userPIIEncryptionService.encryptString(result.text))
        conversation.expiresAt = Date().addingTimeInterval(30 * 86400)
        try await req.db.transaction { database in
            try await assistantMessage.create(on: database)
            try await conversation.save(on: database)
        }
        let messageDTO = try AIMessageResponse(id: assistantMessage.requireID().uuidString,
                                               conversationId: id.uuidString, role: .assistant, content: result.text,
                                               createdAt: ISO8601DateFormatter().string(from: assistantMessage.createdAt ?? Date()))
        let actionDTO: AIPendingActionResponse? = try result.pendingAction.map { action in
            try AIPendingActionResponse(id: action.requireID().uuidString, conversationId: id.uuidString,
                                        toolName: action.toolName,
                                        summary: req.userPIIEncryptionService.decryptString(action.summaryEncrypted),
                                        arguments: req.userPIIEncryptionService.decryptString(action.argumentsEncrypted),
                                        status: .pending, expiresAt: ISO8601DateFormatter().string(from: action.expiresAt),
                                        createdAt: ISO8601DateFormatter().string(from: action.createdAt ?? Date()))
        }
        let response = AIAssistantTurnResponse(kind: actionDTO == nil ? .message : .confirmationRequired,
                                               conversationId: id.uuidString, message: messageDTO, pendingAction: actionDTO)
        let http = Response(status: .ok); try http.content.encode(response, as: .json); return http
    }

    @Sendable func confirmAction(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let result = try await req.db.transaction { database -> AIConfirmedActionExecutor.Result in
            guard let action = try await AIPendingAction.query(on: database)
                .filter(\.$id == id).filter(\.$userId == userId).first()
            else { throw Abort(.notFound) }
            guard action.status == AIActionStatus.pending.rawValue, action.expiresAt > Date() else {
                throw Abort(.conflict, reason: "Action is no longer available for confirmation.")
            }
            let audit = AIActionAudit()
            audit.userId = userId; audit.pendingActionId = id; audit.toolName = action.toolName; audit.status = "executing"
            try await audit.create(on: database)
            action.status = AIActionStatus.confirmed.rawValue
            try await action.save(on: database)
            let argumentsText = try req.userPIIEncryptionService.decryptString(action.argumentsEncrypted)
            guard let arguments = argumentsText.data(using: .utf8) else { throw Abort(.badRequest) }
            let executed = try await AIConfirmedActionExecutor().execute(toolName: action.toolName,
                                                                         arguments: arguments, userId: userId, on: database)
            action.status = AIActionStatus.completed.rawValue
            audit.status = AIActionStatus.completed.rawValue
            try await action.save(on: database); try await audit.save(on: database)
            return executed
        }
        let body = AIConfirmedActionResponse(actionId: id.uuidString, status: .completed,
                                             resultId: result.id?.uuidString, message: result.message)
        let response = Response(status: .ok); try response.content.encode(body, as: .json); return response
    }

    private func consumeAssistantTurn(userId: UUID, req: Request) async throws {
        let billing = try await req.application.billingContextService.context(userId: userId, on: req.db)
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        try await req.db.transaction { database in
            let usage = try await AIAssistantUsage.query(on: database).filter(\.$userId == userId)
                .filter(\.$monthStart == month).first() ?? AIAssistantUsage(userId: userId, monthStart: month)
            guard billing.isPro || usage.requestCount < 5 else {
                throw Abort(.paymentRequired, reason: "The free AI preview includes 5 requests per month.")
            }
            usage.requestCount += 1; try await usage.save(on: database)
        }
    }
}
