import Fluent
import FluentSQL

struct CreateMarketNewsArchive: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("market_news_archive")
            .id()
            .field("provider", .string, .required)
            .field("symbol", .string, .required)
            .field("headline", .string, .required)
            .field("source", .string)
            .field("url", .string)
            .field("summary", .string)
            .field("published_at", .datetime, .required)
            .field("fetched_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(
            on: "market_news_archive",
            columns: ["provider", "symbol", "published_at"],
            name: "idx_market_news_archive_provider_symbol_published_at"
        )
        try await database.createIndex(
            on: "market_news_archive",
            columns: ["provider", "symbol", "fetched_at"],
            name: "idx_market_news_archive_provider_symbol_fetched_at"
        )
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema("market_news_archive").delete()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS idx_market_news_archive_provider_symbol_published_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_market_news_archive_provider_symbol_fetched_at").run()
        try await database.schema("market_news_archive").delete()
    }
}
