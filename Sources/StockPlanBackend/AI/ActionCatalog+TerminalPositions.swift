import Foundation
import StockPlanShared
import Vapor

extension ActionCatalog {
    /// Terminal position sizing for the assistant, Telegram and MCP. Planning
    /// math, not advice. The model never computes the derived numbers: Norviq
    /// returns them. `set_terminal_scenario` is destructive so every surface
    /// confirms before an agent changes a user's assumptions.
    static var terminalPositionActions: [ActionDefinition] {
        let service = TerminalPositionsService()
        let ticker = OpenAIParameter(type: "string", description: "Ticker symbol, e.g. AMZN.")
        let number: (String) -> OpenAIParameter = { OpenAIParameter(type: "number", description: $0) }
        return [
            ActionDefinition(
                "get_terminal_positions",
                "List the user's terminal position scenarios with Norviq-computed terminal share price, shares needed and progress. Assumptions, not forecasts; not financial advice.",
                readOnly: true
            ) { context, _, req in
                let rows = try await service.list(userId: context.userId, on: req.db)
                return try await encode(TerminalPositionsListResponse(
                    currency: service.currency(userId: context.userId, on: req.db),
                    positions: rows.map { $0.toResponse() }
                ))
            },

            ActionDefinition(
                "get_terminal_position",
                "Read the user's terminal scenario for one ticker (the first row for that ticker), with Norviq-computed numbers.",
                properties: ["ticker": ticker],
                required: ["ticker"],
                readOnly: true
            ) { context, args, req in
                guard let raw = args.string("ticker"), let symbol = try? TerminalPositionsService.normalisedTicker(raw) else {
                    return errorPayload("ticker is required")
                }
                guard let row = try await service.list(userId: context.userId, ticker: symbol, on: req.db).first else {
                    return statusPayload("none")
                }
                return try encode(row.toResponse())
            },

            ActionDefinition(
                "lookup_share_facts",
                "Look up a ticker's latest shares outstanding and share price with web search. Returns a sourced suggestion only and never changes the user's data. Requires Norviq Pro.",
                properties: ["ticker": ticker],
                required: ["ticker"],
                readOnly: true
            ) { context, args, req in
                guard let raw = args.string("ticker"), let symbol = try? TerminalPositionsService.normalisedTicker(raw) else {
                    return errorPayload("ticker is required")
                }
                do {
                    try await req.usageCounterService.requirePremium(.terminalPositionAI, userId: context.userId, on: req.db)
                } catch {
                    return errorPayload("lookup_share_facts needs Norviq Pro")
                }
                guard let client = req.application.terminalAIClient else { return errorPayload("AI lookup unavailable") }
                do {
                    let currency = try await service.currency(userId: context.userId, on: req.db)
                    return try await encode(TerminalAIAdvisor(client: client).shareFacts(ticker: symbol, currency: currency, on: req))
                } catch let abort as any AbortError {
                    return errorPayload(abort.reason)
                }
            },

            ActionDefinition(
                "set_terminal_scenario",
                """
                Create or update the user's terminal scenario for a ticker (updates the first row for that ticker). \
                Only use numbers the user stated or that come from a cited source; never invent a market cap or a value \
                wanted. Do not compute derived values yourself: Norviq computes terminal share price = terminalMarketCap / \
                terminalShareCount and shares needed = valueWanted × terminalShareCount / terminalMarketCap. A new scenario \
                needs terminalShareCount, terminalMarketCap and valueWanted. Planning math, not financial advice.
                """,
                properties: [
                    "ticker": ticker,
                    "terminalShareCount": number("Assumed future share count, including dilution."),
                    "terminalMarketCap": number("Assumed future market cap in the user's currency."),
                    "valueWanted": number("What the user wants the position to be worth at the terminal scenario."),
                    "sharesOwned": number("Shares the user already owns."),
                    "sharesOutstanding": number("Current shares outstanding (reference only)."),
                    "currentSharePrice": number("Current share price, if known."),
                ],
                required: ["ticker"],
                destructive: true
            ) { context, args, req in
                guard let raw = args.string("ticker") else { return errorPayload("ticker is required") }
                let fields = TerminalPositionsService.ScenarioFields(
                    terminalShareCount: args.double("terminalShareCount"),
                    terminalMarketCap: args.double("terminalMarketCap"),
                    valueWanted: args.double("valueWanted"),
                    sharesOwned: args.double("sharesOwned"),
                    sharesOutstanding: args.double("sharesOutstanding"),
                    currentSharePrice: args.double("currentSharePrice")
                )
                do {
                    let row = try await service.upsertScenario(userId: context.userId, ticker: raw, fields: fields, on: req.db)
                    return try encode(row.toResponse())
                } catch let abort as any AbortError {
                    return errorPayload(abort.reason)
                }
            },
        ]
    }
}
