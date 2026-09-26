import Fluent
import Foundation
import Vapor

/// `/v1/gamification` (XP, check-ins, streaks) and `/v1/social/leaderboards`.
/// Behind `SOCIAL_ENABLED` like the rest of social, and 404 while
/// `SOCIAL_LEADERBOARDS_ENABLED` is off. The client reports facts; the server
/// decides every point.
struct GamificationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let authed = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped(SocialEnabledMiddleware(), LeaderboardsEnabledMiddleware())

        let gamification = authed.grouped("gamification")
        gamification.get("xp", use: xpSummary)
        gamification.get("xp", "events", use: xpEvents)
        gamification.get("streaks", use: streaks)
        gamification.grouped(RateLimitMiddleware(limit: 20, interval: 60, keyPrefix: "ratelimit:gamification-write"))
            .post("check-in", use: checkIn)
        gamification.grouped(RateLimitMiddleware(limit: 20, interval: 60, keyPrefix: "ratelimit:gamification-write"))
            .post("streaks", "budget", use: reportBudgetStreak)

        authed.grouped("social").get("leaderboards", use: leaderboard)
    }

    @Sendable
    func xpSummary(req: Request) async throws -> XPSummaryDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await XPService.summary(
            for: userId,
            now: Date(),
            timeZone: GamificationCalendar.timeZone(from: req),
            on: req.db
        )
    }

    @Sendable
    func xpEvents(req: Request) async throws -> XPHistoryResponseDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let cursor = req.query[String.self, at: "cursor"]
        let limit = req.query[Int.self, at: "limit"] ?? 30
        return try await XPService.events(for: userId, cursor: cursor, limit: limit, on: req.db)
    }

    @Sendable
    func streaks(req: Request) async throws -> StreakSummaryDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await XPService.streaks(
            for: userId,
            now: Date(),
            timeZone: GamificationCalendar.timeZone(from: req),
            on: req.db
        )
    }

    @Sendable
    func checkIn(req: Request) async throws -> CheckInResponseDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await XPService.checkIn(
            userId: userId,
            now: Date(),
            timeZone: GamificationCalendar.timeZone(from: req),
            on: req.db
        )
    }

    /// The app reports the budget streak it shows; the server re-derives it
    /// from expense data and keeps the lower number.
    @Sendable
    func reportBudgetStreak(req: Request) async throws -> StreakSummaryDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let body = try req.content.decode(BudgetStreakReportBody.self)
        let verified = try await XPService.verifiedBudgetStreak(userId: userId, req: req)
        try await XPService.recordBudgetStreak(userId: userId, reported: body.months, verified: verified, on: req.db)
        return try await XPService.streaks(
            for: userId,
            now: Date(),
            timeZone: GamificationCalendar.timeZone(from: req),
            on: req.db
        )
    }

    @Sendable
    func leaderboard(req: Request) async throws -> LeaderboardResponseDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let metric = LeaderboardMetricDTO(rawValue: req.query[String.self, at: "metric"] ?? "xp") else {
            throw Abort(.badRequest, reason: "Unknown metric.")
        }
        guard let period = LeaderboardPeriodDTO(rawValue: req.query[String.self, at: "period"] ?? "week") else {
            throw Abort(.badRequest, reason: "Unknown period.")
        }
        return try await LeaderboardService.leaderboard(
            metric: metric,
            period: period,
            viewer: userId,
            now: Date(),
            timeZone: GamificationCalendar.timeZone(from: req),
            on: req.db
        )
    }
}

/// 404 while leaderboards and XP are switched off, so the routes can deploy
/// before the app shows them.
struct LeaderboardsEnabledMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard SocialConfiguration.fromEnvironment().leaderboards else {
            throw Abort(.notFound)
        }
        return try await next.respond(to: request)
    }
}
