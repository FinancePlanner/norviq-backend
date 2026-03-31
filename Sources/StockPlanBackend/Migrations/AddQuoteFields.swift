import Fluent

struct AddQuoteFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(QuoteCache.schema)
            .field("change", .double)
            .field("percent_change", .double)
            .field("high", .double)
            .field("low", .double)
            .field("open", .double)
            .field("previous_close", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(QuoteCache.schema)
            .deleteField("change")
            .deleteField("percent_change")
            .deleteField("high")
            .deleteField("low")
            .deleteField("open")
            .deleteField("previous_close")
            .update()
    }
}
