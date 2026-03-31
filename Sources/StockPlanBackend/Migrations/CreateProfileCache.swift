import Fluent

struct CreateProfileCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ProfileCache.schema)
            .id()
            .field("provider", .string, .required)
            .field("symbol", .string, .required)
            .field("country", .string)
            .field("currency", .string)
            .field("estimate_currency", .string)
            .field("exchange", .string)
            .field("finnhub_industry", .string)
            .field("ipo", .string)
            .field("logo", .string)
            .field("market_capitalization", .double)
            .field("name", .string)
            .field("phone", .string)
            .field("share_outstanding", .double)
            .field("ticker", .string)
            .field("weburl", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "provider", "symbol")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ProfileCache.schema).delete()
    }
}
