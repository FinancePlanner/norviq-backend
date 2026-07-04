import Foundation
import Vapor

struct InsightsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())

        let insights = protected.grouped("insights")
        insights.get("summary", use: summary)
        insights.get("topics", ":topic", use: topic)
        insights.get("sentiment", use: sentiment)
        insights.get("net-worth", use: netWorth)
        insights.get("tickers", ":symbol", "sentiment", use: tickerSentiment)
    }

    @Sendable
    func summary(req: Request) async throws -> InsightsSummaryResponse {
        _ = try req.auth.require(SessionToken.self)
        let days = clampedDays(req.query[Int.self, at: "days"], default: 7)
        return try await req.application.insightsService.summary(days: days, on: req.db)
    }

    @Sendable
    func topic(req: Request) async throws -> InsightsTopicResponse {
        _ = try req.auth.require(SessionToken.self)
        guard let topic = req.parameters.get("topic")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topic.isEmpty, topic.count <= 40
        else {
            throw Abort(.badRequest, reason: "Invalid topic.")
        }
        let days = clampedDays(req.query[Int.self, at: "days"], default: 7)
        let limit = clampedLimit(req.query[Int.self, at: "limit"], default: 50)
        return try await req.application.insightsService.topic(topic, days: days, limit: limit, on: req.db)
    }

    @Sendable
    func sentiment(req: Request) async throws -> InsightsSentimentResponse {
        _ = try req.auth.require(SessionToken.self)
        let topic = req.query[String.self, at: "topic"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await req.application.insightsService.sentiment(
            topic: (topic?.isEmpty ?? true) ? nil : topic,
            on: req.db
        )
    }

    @Sendable
    func netWorth(req: Request) async throws -> InsightsNetWorthResponse {
        _ = try req.auth.require(SessionToken.self)
        return try await req.application.insightsService.netWorth(on: req.db)
    }

    @Sendable
    func tickerSentiment(req: Request) async throws -> TickerSentimentResponse {
        _ = try req.auth.require(SessionToken.self)
        let symbol = try validatedSymbol(req.parameters.get("symbol"))
        let days = clampedDays(req.query[Int.self, at: "days"], default: 14)
        let limit = clampedLimit(req.query[Int.self, at: "limit"], default: 20, max: 100)
        return try await req.application.insightsService.tickerSentiment(symbol: symbol, days: days, limit: limit, on: req.db)
    }

    private func validatedSymbol(_ raw: String?) throws -> String {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let symbol = normalized.hasPrefix("$") ? String(normalized.dropFirst()) : normalized
        let pattern = "^[A-Z][A-Z0-9.\\-]{0,9}$"
        guard symbol.range(of: pattern, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid symbol.")
        }
        return symbol
    }

    private func clampedDays(_ raw: Int?, default defaultValue: Int) -> Int {
        max(1, min(raw ?? defaultValue, 90))
    }

    private func clampedLimit(_ raw: Int?, default defaultValue: Int, max maxValue: Int = 200) -> Int {
        Swift.max(1, Swift.min(raw ?? defaultValue, maxValue))
    }
}
