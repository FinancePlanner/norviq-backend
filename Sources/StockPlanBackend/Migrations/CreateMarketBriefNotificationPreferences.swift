import Fluent

struct CreateMarketBriefNotificationPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MarketBriefNotificationPreference.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("enabled", .bool, .required)
            .field("language", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MarketBriefNotificationPreference.schema).delete()
    }
}
