import Fluent
import FluentSQL

/// Articles and their votes, daily view rows and cover images. Content
/// cascades with its author's account.
struct CreateArticlesTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("article_images")
            .id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("content_type", .string, .required)
            .field("bytes", .data, .required)
            .field("width", .int, .required)
            .field("height", .int, .required)
            .field("created_at", .datetime, .required)
            .create()

        try await database.schema("articles")
            .id()
            .field("code", .string, .required)
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("slug", .string, .required)
            .field("title", .string, .required)
            .field("body_markdown", .string, .required)
            .field("bullet_points", .array(of: .string), .required)
            .field("tickers", .array(of: .string), .required)
            .field("disclosure", .string, .required)
            .field("cover_image_id", .uuid, .references("article_images", "id", onDelete: .setNull))
            .field("status", .string, .required)
            .field("source", .string, .required)
            .field("view_count", .int, .required)
            .field("upvote_count", .int, .required)
            .field("word_count", .int, .required)
            .field("published_at", .datetime, .required)
            .field("edited_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "code")
            .create()

        try await database.schema("article_votes")
            .id()
            .field("article_id", .uuid, .required, .references("articles", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "article_id", "user_id")
            .create()

        try await database.schema("article_views")
            .id()
            .field("article_id", .uuid, .required, .references("articles", "id", onDelete: .cascade))
            .field("viewer_key", .string, .required)
            .field("day", .string, .required)
            .unique(on: "article_id", "viewer_key", "day")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS articles_feed_idx ON articles (status, published_at DESC, id DESC)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS articles_tickers_idx ON articles USING GIN (tickers)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS articles_author_idx ON articles (author_id, published_at DESC)").run()
            // The upload cap counts an owner's recent images; the orphan sweep and
            // the image route look articles up by cover.
            try await sql.raw("CREATE INDEX IF NOT EXISTS article_images_owner_idx ON article_images (owner_id, created_at)").run()
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS articles_cover_idx ON articles (cover_image_id) WHERE cover_image_id IS NOT NULL
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("article_views").delete()
        try await database.schema("article_votes").delete()
        try await database.schema("articles").delete()
        try await database.schema("article_images").delete()
    }
}
