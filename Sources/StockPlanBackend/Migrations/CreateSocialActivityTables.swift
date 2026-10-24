import Fluent
import FluentSQL

/// The social layer on top of achievements: the friends' activity feed (one
/// row per shared unlock), congratulations on it, invite redemptions that
/// credit the inviter, and the privacy switch for showing achievements.
///
/// Kinds are text, not enums. Re-runnable: creates skip existing objects.
struct CreateSocialActivityTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("social_activity")
            .id()
            .field("actor_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("user_achievement_id", .uuid, .required, .references("user_achievements", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "user_achievement_id")
            .ignoreExisting()
            .create()

        try await database.schema("social_congrats")
            .id()
            .field("activity_id", .uuid, .required, .references("social_activity", "id", onDelete: .cascade))
            .field("from_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "activity_id", "from_user_id")
            .ignoreExisting()
            .create()

        // One row per invitee: an account is credited to one inviter, once.
        try await database.schema("social_invite_redemptions")
            .id()
            .field("invite_id", .uuid, .required, .references("social_invites", "id", onDelete: .cascade))
            .field("inviter_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("invitee_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("redeemed_at", .datetime, .required)
            .unique(on: "invitee_id")
            .ignoreExisting()
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_social_activity_actor_created
        ON social_activity (actor_id, created_at, id)
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_social_invite_redemptions_inviter
        ON social_invite_redemptions (inviter_id)
        """).run()
        try await sql.raw("""
        ALTER TABLE social_settings
        ADD COLUMN IF NOT EXISTS show_achievements boolean NOT NULL DEFAULT true
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("ALTER TABLE social_settings DROP COLUMN IF EXISTS show_achievements").run()
        }
        try await database.schema("social_invite_redemptions").delete()
        try await database.schema("social_congrats").delete()
        try await database.schema("social_activity").delete()
    }
}
