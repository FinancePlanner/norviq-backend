import Fluent
import Foundation
import Vapor

/// Friends' achievements: `GET /v1/social/users/:userId/achievements`, plus
/// the activity feed routes. All of it 404s unless the activity feed flag is on.
struct SocialFeedController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let feed = routes.grouped("social")
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped(SocialEnabledMiddleware(), ActivityFeedEnabledMiddleware())
        feed.get("users", ":userId", "achievements", use: friendAchievements)
    }

    /// 404 unless the viewer may see the owner's achievements (not a friend,
    /// blocked, suspended, or sharing turned off), so nothing leaks.
    @Sendable
    func friendAchievements(req: Request) async throws -> [AchievementUnlockDTO] {
        let viewer = try req.auth.require(SessionToken.self).userId
        let owner = try SocialController.uuidParameter("userId", on: req)
        let access = try await AchievementVisibility.resolve(viewer: viewer, owner: owner, on: req.db)
        guard access.canSee else { throw Abort(.notFound, reason: "User not found") }
        let language = AchievementLanguage.from(acceptLanguage: req.headers.first(name: .acceptLanguage))
        let rows = try await AchievementVisibility.visibleRows(of: owner, access: access, on: req.db)
        return AchievementVisibility.unlocks(from: rows, language: language)
    }
}

/// 404 unless `SOCIAL_ENABLED`, `ACHIEVEMENTS_ENABLED` and
/// `SOCIAL_ACTIVITY_FEED_ENABLED` are all on.
struct ActivityFeedEnabledMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard SocialConfiguration.fromEnvironment().activityFeed else {
            throw Abort(.notFound)
        }
        return try await next.respond(to: request)
    }
}
