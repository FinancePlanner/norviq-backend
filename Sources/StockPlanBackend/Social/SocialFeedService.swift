import Fluent
import FluentSQL
import Foundation
import SQLKit
import Vapor

/// The friends' activity feed. Applies the same rules as
/// `AchievementVisibility` (friends only, not self, no block either way,
/// owner not suspended, `show_achievements`, performance only with
/// `show_return_percent`) in one SQL query so a page is a page, plus the
/// time rules: within 90 days and after the friendship began.
enum SocialFeedService {
    static let defaultLimit = 20
    static let maxLimit = 50
    static let windowDays: Double = 90
    /// Congrats pushes for one activity are at least this far apart.
    static let pushThrottle: TimeInterval = 10 * 60

    struct Row: Sendable {
        let id: UUID
        let actorId: UUID
        let createdAt: Date
        let achievementKey: String
        let tier: String
    }

    /// Visible activity newest first, after `cursor`, or the one `activityId`.
    /// `limit` rows are returned as asked; callers over-fetch by one to page.
    static func visibleActivity(
        viewer: UUID, activityId: UUID? = nil, cursor: NotificationListCursor? = nil, limit: Int, on db: any Database
    ) async throws -> [Row] {
        guard let sql = db as? any SQLDatabase else { return [] }
        let blocked = try await Array(SocialService.blockedEitherWay(for: viewer, on: db))
        let known = AchievementCatalogue.all.map(\.key)
        let performance = AchievementCatalogue.all.filter(\.isPerformance).map(\.key)
        let now = Date()
        let windowStart = now.addingTimeInterval(-windowDays * 86400)

        var query = SQLQueryString("""
        SELECT a.id AS id, a.actor_id AS actor_id, a.created_at AS created_at,
               ua.achievement_key AS achievement_key, ua.tier AS tier
        FROM social_activity a
        JOIN social_friendships f ON f.user_id = \(bind: viewer) AND f.friend_id = a.actor_id
        JOIN user_achievements ua ON ua.id = a.user_achievement_id
        LEFT JOIN social_settings s ON s.user_id = a.actor_id
        WHERE a.actor_id <> \(bind: viewer)
          AND a.kind = \(bind: AchievementNotifier.activityKind)
          AND a.created_at > \(bind: windowStart)
          AND a.created_at > f.created_at
          AND COALESCE(s.show_achievements, TRUE)
          AND ua.achievement_key IN (\(binds: known))
        """)
        if !performance.isEmpty {
            query.appendInterpolation(unsafeRaw: " AND (ua.achievement_key NOT IN (")
            query.appendInterpolation(binds: performance)
            query.appendInterpolation(unsafeRaw: ") OR COALESCE(s.show_return_percent, FALSE))")
        }
        if !blocked.isEmpty {
            query.appendInterpolation(unsafeRaw: " AND a.actor_id NOT IN (")
            query.appendInterpolation(binds: blocked)
            query.appendInterpolation(unsafeRaw: ")")
        }
        if let activityId {
            query.appendInterpolation(unsafeRaw: " AND a.id = ")
            query.appendInterpolation(bind: activityId)
        }
        if let cursor {
            if let id = cursor.id {
                query.appendInterpolation(unsafeRaw: " AND (a.created_at < ")
                query.appendInterpolation(bind: cursor.createdAt)
                query.appendInterpolation(unsafeRaw: " OR (a.created_at = ")
                query.appendInterpolation(bind: cursor.createdAt)
                query.appendInterpolation(unsafeRaw: " AND a.id < ")
                query.appendInterpolation(bind: id)
                query.appendInterpolation(unsafeRaw: "))")
            } else {
                query.appendInterpolation(unsafeRaw: " AND a.created_at < ")
                query.appendInterpolation(bind: cursor.createdAt)
            }
        }
        query.appendInterpolation(unsafeRaw: " ORDER BY a.created_at DESC, a.id DESC LIMIT ")
        query.appendInterpolation(bind: limit)

        return try await sql.raw(query).all().map { row in
            try Row(
                id: row.decode(column: "id", as: UUID.self),
                actorId: row.decode(column: "actor_id", as: UUID.self),
                createdAt: row.decode(column: "created_at", as: Date.self),
                achievementKey: row.decode(column: "achievement_key", as: String.self),
                tier: row.decode(column: "tier", as: String.self)
            )
        }
    }

    static func feed(
        viewer: UUID, cursor: NotificationListCursor?, limit: Int, language: AchievementLanguage, on db: any Database
    ) async throws -> SocialFeedResponseDTO {
        let rows = try await visibleActivity(viewer: viewer, cursor: cursor, limit: limit + 1, on: db)
        let page = Array(rows.prefix(limit))
        let summaries = try await SocialService.summaries(for: page.map(\.actorId), viewer: viewer, on: db)
        let ids = page.map(\.id)
        let congrats = ids.isEmpty ? [] : try await SocialCongrats.query(on: db).filter(\.$activityId ~~ ids).all()
        var counts: [UUID: Int] = [:]
        var mine = Set<UUID>()
        for row in congrats {
            counts[row.activityId, default: 0] += 1
            if row.fromUserId == viewer {
                mine.insert(row.activityId)
            }
        }
        let items: [SocialFeedItemDTO] = page.compactMap { row in
            guard let actor = summaries[row.actorId], let definition = AchievementCatalogue.definition(row.achievementKey) else { return nil }
            let copy = definition.copy[language] ?? definition.copy[.en] ?? (definition.key, "")
            return SocialFeedItemDTO(
                id: row.id, actor: actor,
                achievement: SocialFeedAchievementDTO(key: row.achievementKey, tier: row.tier, title: copy.title, iconKey: definition.iconKey),
                createdAt: row.createdAt, congratsCount: counts[row.id] ?? 0, viewerCongratulated: mine.contains(row.id)
            )
        }
        let next = rows.count > limit ? page.last.map { NotificationListCursor.encode(createdAt: $0.createdAt, id: $0.id) } : nil
        return SocialFeedResponseDTO(items: items, nextCursor: next)
    }

    /// English push copy for a congrats; the tier is added for a tiered unlock.
    static func congratsMessage(viewerUsername: String, row: Row) -> SocialPushMessage {
        let base = AchievementCatalogue.definition(row.achievementKey)?.copy[.en]?.title ?? "achievement"
        let title = row.tier.isEmpty ? base : "\(base) (\(row.tier.capitalized))"
        return SocialPushMessage(kind: .achievementCongrats, title: "🎉 Congrats", body: "\(viewerUsername) cheered your \(title)")
    }
}
