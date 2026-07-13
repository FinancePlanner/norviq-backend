import Fluent

struct AddInstrumentFundClassification: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Instrument.schema)
            .field("fund_classification", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Instrument.schema)
            .deleteField("fund_classification")
            .update()
    }
}
