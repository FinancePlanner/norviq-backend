import Fluent

struct CreateTaxLossCarryforwardLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(TaxLossCarryforward.schema)
            .id()
            .field("user_id", .uuid, .required)
            .field("jurisdiction", .string, .required)
            .field("source_tax_year", .int, .required)
            .field("expires_after_tax_year", .int, .required)
            .field("original_amount", .double, .required)
            .field("remaining_amount", .double, .required)
            .field("currency", .string, .required)
            .field("rule_version", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "jurisdiction", "source_tax_year")
            .create()

        try await database.schema(TaxLossCarryforwardApplication.schema)
            .id()
            .field(
                "carryforward_id",
                .uuid,
                .required,
                .references(TaxLossCarryforward.schema, .id, onDelete: .cascade)
            )
            .field("target_tax_year", .int, .required)
            .field("amount", .double, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "carryforward_id", "target_tax_year")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(TaxLossCarryforwardApplication.schema).delete()
        try await database.schema(TaxLossCarryforward.schema).delete()
    }
}
