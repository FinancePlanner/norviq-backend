import Fluent

struct CreateFxRate: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("fx_rates")
            .id()
            .field("date", .date, .required)
            .field("base", .string, .required)
            .field("quote", .string, .required)
            .field("rate", .double, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "date", "base", "quote")
            .create()

        try await database.createIndex(on: "fx_rates", columns: ["base", "quote", "date"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("fx_rates").delete()
    }
}
