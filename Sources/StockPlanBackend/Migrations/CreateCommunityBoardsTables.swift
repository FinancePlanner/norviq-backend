import Fluent
import FluentSQL

/// Boards, posts, threaded comments, votes, views, sanctions and guidelines
/// acceptance. Content cascades with its author's account; a board outlives
/// its creator. A deleted parent comment orphans its replies rather than
/// taking them with it, and clients render orphans at the top level.
struct CreateCommunityBoardsTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("boards")
            .id()
            .field("slug", .string, .required)
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("creator_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("post_count", .int, .required)
            .field("last_activity_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .unique(on: "slug")
            .create()
        try await database.createIndex(on: "boards", columns: ["creator_id", "created_at"])

        try await database.schema("board_posts")
            .id()
            .field("board_id", .uuid, .required, .references("boards", "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("title", .string, .required)
            .field("url", .string)
            .field("domain", .string)
            .field("body", .string)
            .field("tags", .array(of: .string), .required)
            .field("score", .int, .required)
            .field("comment_count", .int, .required)
            .field("participant_count", .int, .required)
            .field("view_count", .int, .required)
            .field("last_activity_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .create()
        try await database.createIndex(on: "board_posts", columns: ["board_id", "created_at", "id"])
        try await database.createIndex(on: "board_posts", columns: ["board_id", "last_activity_at", "id"])
        try await database.createIndex(on: "board_posts", columns: ["author_id", "created_at"])
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_board_posts_tags ON board_posts USING GIN (tags)").run()
        }

        try await database.schema("board_comments")
            .id()
            .field("post_id", .uuid, .required, .references("board_posts", "id", onDelete: .cascade))
            .field("parent_id", .uuid, .references("board_comments", "id", onDelete: .setNull))
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("body", .string, .required)
            .field("depth", .int, .required)
            .field("created_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .create()
        try await database.createIndex(on: "board_comments", columns: ["post_id", "created_at"])
        try await database.createIndex(on: "board_comments", columns: ["post_id", "author_id"])

        try await database.schema("board_votes")
            .id()
            .field("post_id", .uuid, .required, .references("board_posts", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "post_id", "user_id")
            .create()

        try await database.schema("board_post_views")
            .id()
            .field("post_id", .uuid, .required, .references("board_posts", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("last_seen_comment_count", .int, .required)
            .field("last_seen_at", .datetime, .required)
            .unique(on: "post_id", "user_id")
            .create()

        try await database.schema("community_sanctions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("reason", .string, .required)
            .field("expires_at", .datetime)
            .field("created_by", .uuid, .references("users", "id", onDelete: .setNull))
            .field("revoked_at", .datetime)
            .field("created_at", .datetime, .required)
            .create()
        try await database.createIndex(on: "community_sanctions", columns: ["user_id", "revoked_at"])

        try await database.schema("community_guidelines_acceptances")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("accepted_at", .datetime, .required)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("community_guidelines_acceptances").delete()
        try await database.schema("community_sanctions").delete()
        try await database.schema("board_post_views").delete()
        try await database.schema("board_votes").delete()
        try await database.schema("board_comments").delete()
        try await database.schema("board_posts").delete()
        try await database.schema("boards").delete()
    }
}
