import Fluent

/// XP ledger, daily check-ins and the verified budget streak. Every user
/// column cascades, so deleting an account removes XP and leaderboard data.
struct CreateGamificationTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("gamification_xp_events")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("type", .string, .required)
            .field("points", .int, .required)
            .field("dedupe_key", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "user_id", "dedupe_key")
            .create()
        try await database.createIndex(on: "gamification_xp_events", columns: ["user_id", "created_at"])

        try await database.schema("gamification_check_ins")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("local_date", .string, .required)
            .field("time_zone", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "user_id", "local_date")
            .create()

        try await database.schema("gamification_budget_streaks")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("months", .int, .required)
            .field("best_months", .int, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("gamification_budget_streaks").delete()
        try await database.schema("gamification_check_ins").delete()
        try await database.schema("gamification_xp_events").delete()
    }
}
