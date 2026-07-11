import Foundation
import StockPlanShared
import Vapor

/// Tools the in-app assistant may call. Mirrors the norviq-mcp tool surface
/// (same names/semantics) but executes services in-process. As with
/// `AIToolRegistry`, the userId is bound server-side and is never a model-visible
/// parameter, so cross-user access is not expressible. Write tools require an
/// explicit confirm step for destructive actions.
enum AIChatToolRegistry {
    static func toolDefinitions() -> [OpenAITool] {
        [
            tool("get_financial_overview", "The user's portfolio overview: total value, P&L, allocation, cash, savings rate."),
            tool("list_expenses", "List the user's recent expenses.", [
                "month": OpenAIParameter(type: "integer", description: "1-12, optional"),
                "year": OpenAIParameter(type: "integer", description: "e.g. 2026, optional"),
                "limit": OpenAIParameter(type: "integer", description: "max rows, optional"),
            ]),
            tool("add_expense", "Add a new expense.", [
                "title": OpenAIParameter(type: "string"),
                "amount": OpenAIParameter(type: "number"),
                "pillar": OpenAIParameter(type: "string", description: "one of fundamentals, futureYou, fun", enumValues: ["fundamentals", "futureYou", "fun"]),
                "occurred_on": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
            ], required: ["title", "amount", "pillar", "occurred_on"]),
            tool("update_expense", "Update fields of an existing expense.", [
                "id": OpenAIParameter(type: "string"),
                "title": OpenAIParameter(type: "string"),
                "amount": OpenAIParameter(type: "number"),
                "pillar": OpenAIParameter(type: "string", enumValues: ["fundamentals", "futureYou", "fun"]),
                "occurred_on": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
            ], required: ["id"]),
            tool("delete_expense", "Delete an expense. Returns needs_confirmation unless confirm=true; ask the user to confirm first.", [
                "id": OpenAIParameter(type: "string"),
                "confirm": OpenAIParameter(type: "boolean", description: "must be true to actually delete"),
            ], required: ["id"]),
            tool("get_spending_report", "The user's monthly spending report.", [
                "months": OpenAIParameter(type: "integer", description: "how many recent months, optional"),
            ]),
            tool("get_quote", "Latest market quote for a symbol.", [
                "symbol": OpenAIParameter(type: "string", description: "ticker, e.g. AAPL"),
            ], required: ["symbol"]),
            tool("search_symbols", "Search stocks/ETFs by name or ticker.", [
                "query": OpenAIParameter(type: "string"),
            ], required: ["query"]),
            tool("get_insights", "Latest market sentiment insights summary."),
        ]
    }

    /// Executes a tool, returning a JSON string result for the model.
    static func execute(name: String, arguments: String, context: AIToolContext, on req: Request) async throws -> String {
        let args = parseArgs(arguments)
        switch name {
        case "get_financial_overview":
            return try await encode(req.application.dashboardService.dashboard(userId: context.userId, req: req, on: req.db))

        case "list_expenses":
            let result = try await req.expensesService.getExpenses(
                userId: context.userId, from: nil, to: nil, limit: intArg(args, "limit") ?? 50, cursor: nil, on: req.db
            )
            return try encode(result.items)

        case "add_expense":
            guard let title = stringArg(args, "title"), let amount = doubleArg(args, "amount"),
                  let pillarRaw = stringArg(args, "pillar"), let occurredOn = stringArg(args, "occurred_on")
            else {
                return #"{"error":"missing required fields"}"#
            }
            guard let pillar = BudgetPillar(rawValue: pillarRaw) else {
                return #"{"error":"invalid pillar; use fundamentals, futureYou, or fun"}"#
            }
            let created = try await req.expensesService.createExpense(
                userId: context.userId,
                request: ExpenseRequest(title: title, amount: amount, pillar: pillar, occurredOn: occurredOn),
                on: req.db
            )
            return try encode(created)

        case "update_expense":
            guard let idStr = stringArg(args, "id"), let id = UUID(uuidString: idStr) else {
                return #"{"error":"invalid id"}"#
            }
            // Fetch existing to preserve unspecified fields.
            let existing = try await req.expensesService.getExpenses(
                userId: context.userId, from: nil, to: nil, limit: 10000, cursor: nil, on: req.db
            ).items.first { $0.id == idStr }
            guard let existing else { return #"{"error":"expense not found"}"# }
            let pillar = stringArg(args, "pillar").flatMap { BudgetPillar(rawValue: $0) } ?? existing.pillar
            let updated = try await req.expensesService.updateExpense(
                userId: context.userId, expenseId: id,
                request: ExpenseRequest(
                    title: stringArg(args, "title") ?? existing.title,
                    amount: doubleArg(args, "amount") ?? existing.amount,
                    pillar: pillar,
                    occurredOn: stringArg(args, "occurred_on") ?? existing.occurredOn,
                    categoryId: existing.categoryId
                ),
                on: req.db
            )
            return try encode(updated)

        case "delete_expense":
            guard let idStr = stringArg(args, "id"), let id = UUID(uuidString: idStr) else {
                return #"{"error":"invalid id"}"#
            }
            guard boolArg(args, "confirm") == true else {
                return #"{"status":"needs_confirmation","message":"Ask the user to confirm deletion, then call again with confirm=true."}"#
            }
            try await req.expensesService.deleteExpense(userId: context.userId, expenseId: id, on: req.db)
            return #"{"status":"deleted"}"#

        case "get_spending_report":
            let reports = try await req.expensesService.getMonthlyReports(
                userId: context.userId, from: nil, to: nil, on: req.db
            )
            return try encode(reports)

        case "get_quote":
            guard let symbol = stringArg(args, "symbol") else { return #"{"error":"missing symbol"}"# }
            return try await encode(req.application.marketDataService.quote(symbol: symbol, on: req))

        case "search_symbols":
            guard let query = stringArg(args, "query") else { return #"{"error":"missing query"}"# }
            return try await encode(req.application.marketDataService.search(query: query, on: req))

        case "get_insights":
            // Third-party social text — wrap as untrusted so the model treats
            // any embedded instructions as data.
            let summary = try await req.application.insightsService.summary(days: 7, on: req.db)
            return try "{\"untrusted_data\":" + encode(summary) + "}"

        default:
            return #"{"error":"unknown tool"}"#
        }
    }

    // MARK: - Helpers

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: OpenAIParameter] = [:],
                             required: [String] = []) -> OpenAITool
    {
        OpenAITool(function: OpenAIFunctionDef(
            name: name, description: description,
            parameters: OpenAIJSONSchema(properties: properties, required: required)
        ))
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return obj
    }

    private static func stringArg(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func doubleArg(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double {
            return d
        }
        if let i = args[key] as? Int {
            return Double(i)
        }
        if let s = args[key] as? String {
            return Double(s)
        }
        return nil
    }

    private static func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int {
            return i
        }
        if let d = args[key] as? Double {
            return Int(d)
        }
        if let s = args[key] as? String {
            return Int(s)
        }
        return nil
    }

    private static func boolArg(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool {
            return b
        }
        if let s = args[key] as? String {
            return s == "true"
        }
        return nil
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
