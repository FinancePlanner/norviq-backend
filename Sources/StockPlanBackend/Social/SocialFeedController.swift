import Fluent
import FluentSQL
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
        feed.get("feed", use: list)
        feed.grouped(RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:social-congrats"))
            .post("feed", ":activityId", "congrats", use: congratulate)
    }

    @Sendable
    func list(req: Request) async throws -> SocialFeedResponseDTO {
        let viewer = try req.auth.require(SessionToken.self).userId
        let requested = try req.query.get(Int?.self, at: "limit") ?? SocialFeedService.defaultLimit
        let limit = min(max(requested, 1), SocialFeedService.maxLimit)
        let rawCursor = try req.query.get(String?.self, at: "cursor")
        let cursor = NotificationListCursor.parse(rawCursor)
        if let rawCursor, !rawCursor.isEmpty, cursor == nil {
            throw Abort(.badRequest, reason: "Invalid cursor")
        }
        let language = AchievementLanguage.from(acceptLanguage: req.headers.first(name: .acceptLanguage))
        return try await SocialFeedService.feed(viewer: viewer, cursor: cursor, limit: limit, language: language, on: req.db)
    }

    /// 204 whether or not this call created the congrats. The actor is pushed
    /// only for a new one, at most once per 10 minutes per activity.
    @Sendable
    func congratulate(req: Request) async throws -> HTTPStatus {
        let viewer = try req.auth.require(SessionToken.self).userId
        let activityId = try SocialController.uuidParameter("activityId", on: req)
        if let activity = try await SocialActivity.find(activityId, on: req.db), activity.actorId == viewer {
            throw Abort(.badRequest, reason: "You cannot congratulate yourself")
        }
        guard let row = try await SocialFeedService.visibleActivity(viewer: viewer, activityId: activityId, limit: 1, on: req.db).first else {
            throw Abort(.notFound, reason: "Activity not found")
        }
        let now = Date()
        let recent = try await SocialCongrats.query(on: req.db)
            .filter(\.$activityId == activityId)
            .filter(\.$createdAt >= now.addingTimeInterval(-SocialFeedService.pushThrottle))
            .count()
        let inserted = try await insertCongrats(activityId: activityId, from: viewer, at: now, on: req.db)
        if inserted, recent == 0 {
            await pushCongrats(req: req, viewer: viewer, row: row)
        }
        return .noContent
    }

    private func insertCongrats(activityId: UUID, from viewer: UUID, at date: Date, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { return false }
        let rows = try await sql.raw("""
        INSERT INTO social_congrats (id, activity_id, from_user_id, created_at)
        VALUES (\(bind: UUID()), \(bind: activityId), \(bind: viewer), \(bind: date))
        ON CONFLICT (activity_id, from_user_id) DO NOTHING
        RETURNING id
        """).all()
        return !rows.isEmpty
    }

    /// Best effort: a failure here never fails the request.
    private func pushCongrats(req: Request, viewer: UUID, row: SocialFeedService.Row) async {
        do {
            guard let username = try await User.find(viewer, on: req.db)?.username else { return }
            let devices = try await req.pushDeviceService.activeDevices(userId: row.actorId, on: req.db).filter { device in
                let values = (try? JSONDecoder().decode([String].self, from: Data(device.capabilitiesJSON.utf8))) ?? []
                return values.contains(AchievementNotifier.capability)
            }
            guard !devices.isEmpty else { return }
            _ = await req.application.pushNotificationSender.sendSocialEvent(
                message: SocialFeedService.congratsMessage(viewerUsername: username, row: row), devices: devices, req: req
            )
        } catch {
            req.logger.warning("social.congrats.push failed error=\(String(reflecting: type(of: error)))")
        }
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
