import Fluent

struct CreateNewsTickerTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(NewsTickerPreference.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("enabled", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()

        try await database.schema(NewsTickerFeedSubscription.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("feed_url", .string, .required)
            .field("title", .string)
            .field("created_at", .datetime)
            .unique(on: "user_id", "feed_url")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(NewsTickerFeedSubscription.schema).delete()
        try await database.schema(NewsTickerPreference.schema).delete()
    }
}
