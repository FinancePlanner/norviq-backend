import Fluent

struct CreateMarketBriefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("market_briefs")
            .id()
            .field("trading_date", .string, .required)
            .field("slot", .string, .required)
            .field("language", .string, .required)
            .field("payload", .string, .required)
            .field("model", .string, .required)
            .field("degraded", .bool, .required)
            .field("generated_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "trading_date", "slot", "language")
            .create()

        try await database.createIndex(on: "market_briefs", columns: ["language", "generated_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("market_briefs").delete()
    }
}
