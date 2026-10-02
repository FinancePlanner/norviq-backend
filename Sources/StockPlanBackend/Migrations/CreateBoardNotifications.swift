import Fluent
import FluentSQL

/// The Boards activity feed (replies and upvotes) and its push preferences.
/// Kept apart from `notification_events`: that inbox decodes its kinds
/// strictly on older iOS builds, so a new kind there would break them.
struct CreateBoardNotifications: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("board_notifications")
            .id()
            .field("recipient_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("actor_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("post_id", .uuid, .required, .references("board_posts", "id", onDelete: .cascade))
            .field("comment_id", .uuid, .references("board_comments", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .field("read_at", .datetime)
            .create()
        try await database.createIndex(on: "board_notifications", columns: ["recipient_id", "created_at", "id"])
        if let sql = database as? any SQLDatabase {
            // One upvote notification per voter per post, however often they toggle.
            try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS uq_board_notifications_upvote
            ON board_notifications (post_id, actor_id) WHERE kind = 'upvote'
            """).run()
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_board_notifications_unread
            ON board_notifications (recipient_id) WHERE read_at IS NULL
            """).run()
        }

        try await database.schema("board_notification_settings")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("reply_push", .bool, .required)
            .field("upvote_push", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("board_notification_settings").delete()
        try await database.schema("board_notifications").delete()
    }
}
