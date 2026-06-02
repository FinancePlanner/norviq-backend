import Foundation
import NIOCore
import Redis
import RediStack
import StockPlanShared
import Vapor

struct AIInsightsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let insights = protected.grouped("ai", "insights")

        insights.get("expenses", use: expenses)
        insights.get("portfolio", use: portfolio)
        insights.get("summary", use: summary)
    }

    @Sendable
    func expenses(req: Request) async throws -> AIInsightCardResponse {
        try await generate(.expenses, req)
    }

    @Sendable
    func portfolio(req: Request) async throws -> AIInsightCardResponse {
        try await generate(.portfolio, req)
    }

    @Sendable
    func summary(req: Request) async throws -> AIInsightCardResponse {
        try await generate(.summary, req)
    }

    // MARK: - Helpers

    private func generate(_ kind: AIInsightKind, _ req: Request) async throws -> AIInsightCardResponse {
        let session = try await requireAIEntitlement(req)
        try await enforceDailyCap(req, userId: session.userId)
        return try await req.application.aiInsightsService.generate(
            kind: kind, userId: session.userId, on: req
        )
    }

    /// Pro/trial gate — mirrors `requireCryptoEntitlement` in CryptoController.
    private func requireAIEntitlement(_ req: Request) async throws -> SessionToken {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.aiInsights, userId: session.userId, on: req.db)
        return session
    }

    /// Per-user daily generation cap, bounding LLM spend per account. Backed by a
    /// Redis day-bucketed counter. Mirrors RateLimitMiddleware's graceful behavior:
    /// in non-production with Redis absent it is skipped; in production an
    /// unavailable Redis fails closed.
    private func enforceDailyCap(_ req: Request, userId: UUID) async throws {
        let limit = Environment.get("AI_DAILY_LIMIT").flatMap(Int.init) ?? 50
        guard req.application.redis.configuration != nil else {
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "AI insights are temporarily unavailable.")
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
                req.logger.error("ai_daily_cap unavailable userId=\(userId)")
                throw Abort(.serviceUnavailable, reason: "AI insights are temporarily unavailable.")
            }
            return
        }

        guard count <= limit else {
            throw Abort(.tooManyRequests, reason: "Daily AI insight limit reached. Try again tomorrow.")
        }
    }
}

private extension ISO8601DateFormatter {
    static func dayBucket(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
