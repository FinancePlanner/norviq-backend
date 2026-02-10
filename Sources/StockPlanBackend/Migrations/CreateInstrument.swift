import Fluent

struct CreateInstrument: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("instruments")
            .id()
            .field("conid", .string, .required)
            .field("symbol", .string, .required)
            .field("exchange", .string, .required)
            .field("currency", .string, .required)
            .field("name", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "conid", "exchange", "currency")
            .create()

        try await database.createIndex(on: "instruments", columns: ["symbol"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("instruments").delete()
    }
}
