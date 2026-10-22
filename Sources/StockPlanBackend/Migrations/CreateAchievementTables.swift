import Fluent
import FluentSQL

/// Achievements engine tables. Keys, tiers and sources are text, not enums.
/// Every user that exists now is queued for a backfill; the legacy badge
/// rows are copied across as already-seen unlocks.
struct CreateAchievementTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_achievements")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("achievement_key", .string, .required)
            .field("tier", .string, .required, .sql(.default("")))
            .field("unlocked_at", .datetime, .required)
            .field("source", .string, .required)
            .field("seen_at", .datetime)
            .field("notified_at", .datetime)
            .field("showcase_rank", .int)
            .field("created_at", .datetime)
            .unique(on: "user_id", "achievement_key", "tier")
            .create()
        try await database.createIndex(on: "user_achievements", columns: ["user_id", "unlocked_at"])

        try await database.schema("achievement_evaluations")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("needs_backfill", .bool, .required)
            .field("last_evaluated_at", .datetime)
            .field("last_swept_at", .datetime)
            .unique(on: "user_id")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS uq_user_achievements_showcase
        ON user_achievements (user_id, showcase_rank) WHERE showcase_rank IS NOT NULL
        """).run()
        try await sql.raw("""
        ALTER TABLE gamification_xp_events
        ADD COLUMN IF NOT EXISTS exclude_from_leaderboard boolean NOT NULL DEFAULT false
        """).run()
        try await sql.raw("""
        INSERT INTO achievement_evaluations (id, user_id, needs_backfill)
        SELECT gen_random_uuid(), id, true FROM users
        """).run()
        try await sql.raw("""
        INSERT INTO user_achievements (id, user_id, achievement_key, tier, unlocked_at, source, seen_at, created_at)
        SELECT gen_random_uuid(), user_id, 'legacy.' || badge_type::text, tier::text, earned_at, 'legacy_badge', earned_at, now()
        FROM user_badges
        ON CONFLICT DO NOTHING
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("ALTER TABLE gamification_xp_events DROP COLUMN IF EXISTS exclude_from_leaderboard").run()
        }
        try await database.schema("achievement_evaluations").delete()
        try await database.schema("user_achievements").delete()
    }
}
