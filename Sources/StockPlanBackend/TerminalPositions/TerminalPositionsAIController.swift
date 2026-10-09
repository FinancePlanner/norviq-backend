import Foundation
import StockPlanShared
import Vapor

extension ShareFactsRequest: @retroactive Content {}
extension ShareFactsSuggestion: @retroactive Content {}
extension TerminalScenarioSuggestionRequest: @retroactive Content {}
extension TerminalScenarioSuggestion: @retroactive Content {}

/// Pro-only AI suggestions. Registered under the AI rate limit. Suggestions
/// are returned, never stored.
struct TerminalPositionsAIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ai = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped("terminal-positions", "ai")
            .grouped(ScopeRequirementMiddleware(.planningRead))
        ai.post("share-facts", use: shareFacts)
        ai.post("scenario", use: scenario)
    }

    private func advisor(_ req: Request) async throws -> TerminalAIAdvisor {
        let userId = try req.auth.require(SessionToken.self).userId
        try await req.usageCounterService.requirePremium(.terminalPositionAI, userId: userId, on: req.db)
        guard let client = req.application.terminalAIClient else {
            throw Abort(.serviceUnavailable, reason: "AI lookup unavailable. Try again later or enter the numbers yourself.")
        }
        return TerminalAIAdvisor(client: client)
    }

    @Sendable
    func shareFacts(req: Request) async throws -> ShareFactsSuggestion {
        let advisor = try await advisor(req)
        let input = try req.content.decode(ShareFactsRequest.self)
        return try await advisor.shareFacts(ticker: TerminalPositionsService.normalisedTicker(input.ticker), on: req)
    }

    @Sendable
    func scenario(req: Request) async throws -> TerminalScenarioSuggestion {
        let advisor = try await advisor(req)
        let input = try req.content.decode(TerminalScenarioSuggestionRequest.self)
        return try await advisor.scenario(
            ticker: TerminalPositionsService.normalisedTicker(input.ticker),
            horizonYears: input.horizonYears,
            on: req
        )
    }
}
