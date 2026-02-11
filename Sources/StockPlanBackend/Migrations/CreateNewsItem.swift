import Fluent

struct CreateNewsItem: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("news_items")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("headline", .string, .required)
            .field("source", .string)
            .field("url", .string)
            .field("summary", .string)
            .field("published_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "news_items", columns: ["user_id"])
        try await database.createIndex(on: "news_items", columns: ["user_id", "symbol"])
        try await database.createIndex(on: "news_items", columns: ["user_id", "published_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("news_items").delete()
    }
}
