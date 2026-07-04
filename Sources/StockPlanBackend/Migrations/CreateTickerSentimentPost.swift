import Fluent

struct CreateTickerSentimentPost: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("ticker_sentiment_posts")
            .id()
            .field("dedupe_key", .string, .required)
            .field("symbol", .string, .required)
            .field("author", .string)
            .field("author_handle", .string)
            .field("text", .string, .required)
            .field("url", .string)
            .field("sentiment_label", .string, .required)
            .field("sentiment_score", .double)
            .field("confidence", .double)
            .field("posted_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "dedupe_key")
            .create()

        try await database.createIndex(on: "ticker_sentiment_posts", columns: ["symbol", "posted_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("ticker_sentiment_posts").delete()
    }
}
