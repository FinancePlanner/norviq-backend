import Fluent

struct AddInstrumentMarketAdmissionEvidence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Instrument.schema)
            .field("regulated_market_source", .string)
            .field("regulated_market_reviewed_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Instrument.schema)
            .deleteField("regulated_market_reviewed_at")
            .deleteField("regulated_market_source")
            .update()
    }
}
