import Fluent
import Vapor

/// `/v1/achievements`: the caller's own achievements. 404 while
/// `ACHIEVEMENTS_ENABLED` is off; independent of `SOCIAL_ENABLED`.
struct AchievementController: RouteCollection {
    /// A listing re-evaluates only if the last evaluation is older than this.
    static let evaluationDebounce: TimeInterval = 60

    func boot(routes: any RoutesBuilder) throws {
        let authed = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped(AchievementsEnabledMiddleware())
        let group = authed.grouped("achievements")
        group.get(use: list)
        group.get("unseen", use: unseen)

        let write = group.grouped(RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:achievements-write"))
        write.post("seen", use: markSeen)
        write.put("showcase", use: setShowcase)
    }

    private func language(_ req: Request) -> AchievementLanguage {
        AchievementLanguage.from(acceptLanguage: req.headers.first(name: .acceptLanguage))
    }

    private func context(_ req: Request) -> AchievementContext {
        AchievementContext(db: req.db, logger: req.logger, app: req.application, now: Date())
    }

    @Sendable
    func list(req: Request) async throws -> AchievementsResponseDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let ctx = context(req)
        let last = try await AchievementEvaluation.query(on: req.db)
            .filter(\.$userId == userId).first()?.lastEvaluatedAt
        if last == nil || ctx.now.timeIntervalSince(last ?? ctx.now) >= Self.evaluationDebounce {
            do {
                try await AchievementService.evaluate(userId: userId, scope: .live, ctx: ctx)
            } catch {
                req.logger.warning("achievements.list evaluate failed error=\(String(reflecting: type(of: error)))")
            }
        }
        return try await AchievementService.list(userId: userId, language: language(req), ctx: ctx)
    }

    @Sendable
    func unseen(req: Request) async throws -> [AchievementUnlockDTO] {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await AchievementService.unseen(userId: userId, language: language(req), on: req.db)
    }

    @Sendable
    func markSeen(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let body = try req.content.decode(AchievementSeenBody.self)
        try await AchievementService.markSeen(userId: userId, ids: body.ids, on: req.db)
        return .noContent
    }

    @Sendable
    func setShowcase(req: Request) async throws -> AchievementsResponseDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let body = try req.content.decode(AchievementShowcaseBody.self)
        return try await AchievementService.setShowcase(
            userId: userId, items: body.items, language: language(req), ctx: context(req)
        )
    }
}
