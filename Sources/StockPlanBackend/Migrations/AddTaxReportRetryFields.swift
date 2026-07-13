import Fluent

struct AddTaxReportRetryFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(TaxReport.schema)
            .field("attempt_count", .int)
            .field("next_attempt_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(TaxReport.schema)
            .deleteField("next_attempt_at")
            .deleteField("attempt_count")
            .update()
    }
}
