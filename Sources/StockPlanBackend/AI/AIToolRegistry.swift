import Foundation
import Vapor

/// The single source of the user's identity for a generation request. Captured
/// once from the authenticated session and threaded into every tool call.
/// The model never sees this value and cannot supply one of its own.
struct AIToolContext {
    let userId: UUID
}

/// Defines the tools the model may call and executes them scoped to the bound
/// userId. This is the isolation boundary: every tool reads ONLY the bound
/// user's data via existing per-user aggregators. No tool accepts a userId
/// argument, so cross-user access is not expressible.
enum AIToolRegistry {
    /// Tool schemas advertised to the model. All take zero arguments.
    static func toolDefinitions() -> [OpenAITool] {
        let noArgs = OpenAIJSONSchema()
        return [
            OpenAITool(function: OpenAIFunctionDef(
                name: "get_financial_overview",
                description: """
                The user's current portfolio overview: total value, daily and total P&L, \
                asset allocation, cash buffer, savings rate, and a financial-health summary.
                """,
                parameters: noArgs
            )),
            OpenAITool(function: OpenAIFunctionDef(
                name: "get_expense_report",
                description: """
                The user's recent monthly expense reports: spend per pillar \
                (fundamentals, futureYou, fun), budget targets vs actuals, and savings rate per month.
                """,
                parameters: noArgs
            )),
            OpenAITool(function: OpenAIFunctionDef(
                name: "get_budget_planning",
                description: """
                The user's current-month pillar budget-planning summary: planned vs \
                allocated amounts per spending pillar.
                """,
                parameters: noArgs
            )),
        ]
    }

    /// Execute a named tool for the bound user, returning a JSON string the model
    /// can read. Unknown tools return a structured error rather than throwing, so
    /// a hallucinated tool name does not abort the whole request.
    static func execute(name: String, context: AIToolContext, on req: Request) async throws -> String {
        switch name {
        case "get_financial_overview":
            let dto = try await req.application.dashboardService.dashboard(
                userId: context.userId, req: req, on: req.db
            )
            return try encode(dto)

        case "get_expense_report":
            let dto = try await req.expensesService.getMonthlyReports(
                userId: context.userId, from: nil, to: nil, on: req.db
            )
            return try encode(dto)

        case "get_budget_planning":
            let dto = try await req.expensesService.getPillarPlanningSummaries(
                userId: context.userId, monthStart: currentMonthStart(), on: req.db
            )
            return try encode(dto)

        default:
            return #"{"error":"unknown tool"}"#
        }
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func currentMonthStart() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: components) ?? Date()
    }
}
