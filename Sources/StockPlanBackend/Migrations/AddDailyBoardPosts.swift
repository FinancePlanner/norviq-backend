import Fluent
import FluentSQL

/// The daily AI post is a normal board post plus a run row per trading date.
/// The partial unique index is what stops two replicas publishing the same day.
struct AddDailyBoardPosts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("board_posts")
            .field("ai_generated", .bool, .required, .sql(.default(false)))
            .field("ai_topic", .string)
            .field("trading_date", .string)
            .update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS board_posts_ai_trading_date_idx
            ON board_posts (trading_date)
            WHERE ai_generated AND deleted_at IS NULL
            """).run()
        }
        try await database.schema("daily_board_post_runs")
            .field("trading_date", .string, .identifier(auto: false))
            .field("status", .string, .required)
            .field("post_id", .uuid, .references("board_posts", "id", onDelete: .setNull))
            .field("topic", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("daily_board_post_runs").delete()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS board_posts_ai_trading_date_idx").run()
        }
        try await database.schema("board_posts")
            .deleteField("ai_generated")
            .deleteField("ai_topic")
            .deleteField("trading_date")
            .update()
    }
}
