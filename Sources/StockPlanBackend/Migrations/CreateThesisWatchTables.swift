import Fluent
import FluentSQL

struct CreateThesisWatchTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ThesisWatchStoryModel.schema)
            .id()
            .field("cluster_key", .string, .required)
            .field("representative_news_id", .uuid, .required, .references(MarketNewsArchive.schema, "id", onDelete: .cascade))
            .field("event_type", .string, .required)
            .field("severity", .string, .required)
            .field("first_seen_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "cluster_key")
            .create()

        try await database.schema(MarketNewsArchive.schema)
            .field("story_id", .uuid, .references(ThesisWatchStoryModel.schema, "id", onDelete: .setNull))
            .update()

        try await database.schema(ThesisWatchUserState.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("story_id", .uuid, .required, .references(ThesisWatchStoryModel.schema, "id", onDelete: .cascade))
            .field("symbol", .string)
            .field("impact", .string, .required)
            .field("confidence", .double)
            .field("summary", .string)
            .field("why_it_matters", .string)
            .field("feedback", .string)
            .field("read_at", .datetime)
            .field("dismissed_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "story_id")
            .create()

        try await database.schema(ThesisWatchNotificationPreference.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("enabled", .bool, .required)
            .field("timezone", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX idx_thesis_watch_stories_last_seen ON thesis_watch_stories (last_seen_at DESC)").run()
            try await sql.raw("CREATE INDEX idx_thesis_watch_user_states_user ON thesis_watch_user_states (user_id, dismissed_at)").run()
            try await sql.raw("CREATE INDEX idx_market_news_archive_story ON market_news_archive (story_id)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ThesisWatchNotificationPreference.schema).delete()
        try await database.schema(ThesisWatchUserState.schema).delete()
        try await database.schema(MarketNewsArchive.schema).deleteField("story_id").update()
        try await database.schema(ThesisWatchStoryModel.schema).delete()
    }
}
