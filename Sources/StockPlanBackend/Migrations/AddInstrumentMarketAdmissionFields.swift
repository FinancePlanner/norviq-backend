import Fluent

struct AddInstrumentMarketAdmissionFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Instrument.schema)
            .field("listing_exchange", .string)
            .field("regulated_market_status", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Instrument.schema)
            .deleteField("regulated_market_status")
            .deleteField("listing_exchange")
            .update()
    }
}
