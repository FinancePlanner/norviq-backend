import Fluent

struct AddImageURLToMarketNewsArchive: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("market_news_archive")
            .field("image_url", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("market_news_archive")
            .deleteField("image_url")
            .update()
    }
}
