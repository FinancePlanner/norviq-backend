import Fluent

struct CreatePriceHistory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("price_history")
            .id()
            .field("symbol", .string, .required)
            .field("date", .date, .required)
            .field("open", .double, .required)
            .field("high", .double, .required)
            .field("low", .double, .required)
            .field("close", .double, .required)
            .field("volume", .int)
            .field("created_at", .datetime, .required)
            .unique(on: "symbol", "date")
            .create()

        try await database.createIndex(on: "price_history", columns: ["symbol", "date"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("price_history").delete()
    }
}
