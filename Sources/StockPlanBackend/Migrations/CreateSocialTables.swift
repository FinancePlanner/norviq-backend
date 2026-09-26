import Fluent

/// Friends graph, blocks, reports, privacy settings and invites. Every user
/// column cascades, so deleting an account removes its whole social footprint
/// (reports it filed included; reports about it stay, keyed by string id).
struct CreateSocialTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("social_friend_requests")
            .id()
            .field("from_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("to_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "from_user_id", "to_user_id")
            .create()
        try await database.createIndex(on: "social_friend_requests", columns: ["to_user_id"])

        try await database.schema("social_friendships")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("friend_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "user_id", "friend_id")
            .create()
        try await database.createIndex(on: "social_friendships", columns: ["friend_id"])

        try await database.schema("social_blocks")
            .id()
            .field("blocker_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("blocked_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "blocker_id", "blocked_id")
            .create()
        try await database.createIndex(on: "social_blocks", columns: ["blocked_id"])

        try await database.schema("social_reports")
            .id()
            .field("reporter_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("target_type", .string, .required)
            .field("target_id", .string, .required)
            .field("reason", .string, .required)
            .field("note", .string)
            .field("status", .string, .required)
            .field("created_at", .datetime, .required)
            .create()
        try await database.createIndex(on: "social_reports", columns: ["status"])

        try await database.schema("social_settings")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("search_visibility", .string, .required)
            .field("discoverable_by_contacts", .bool, .required)
            .field("discoverable_by_x", .bool, .required)
            .field("show_return_percent", .bool, .required)
            .field("show_streaks", .bool, .required)
            .field("show_xp", .bool, .required)
            .field("leaderboard_opt_in", .bool, .required)
            .field("email_hash", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
        try await database.createIndex(on: "social_settings", columns: ["email_hash"])

        try await database.schema("social_invites")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "user_id")
            .unique(on: "code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("social_invites").delete()
        try await database.schema("social_settings").delete()
        try await database.schema("social_reports").delete()
        try await database.schema("social_blocks").delete()
        try await database.schema("social_friendships").delete()
        try await database.schema("social_friend_requests").delete()
    }
}
