import Fluent

struct CreatePrice: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("prices")
            .id()
            .field("instrument_id", .uuid, .required, .references("instruments", "id", onDelete: .cascade))
            .field("date", .date, .required)
            .field("open", .double, .required)
            .field("high", .double, .required)
            .field("low", .double, .required)
            .field("close", .double, .required)
            .field("volume", .int)
            .field("currency", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "instrument_id", "date")
            .create()

        try await database.createIndex(on: "prices", columns: ["instrument_id", "date"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("prices").delete()
    }
}
