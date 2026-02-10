import Fluent

struct CreateQuoteCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("quote_cache")
            .id()
            .field("provider", .string, .required)
            .field("symbol", .string, .required)
            .field("currency", .string, .required)
            .field("price", .double, .required)
            .field("as_of", .datetime, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "provider", "symbol")
            .create()

        try await database.createIndex(
            on: "quote_cache",
            columns: ["provider", "symbol", "as_of"],
            name: "idx_quote_cache_provider_symbol_as_of"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("quote_cache").delete()
    }
}
