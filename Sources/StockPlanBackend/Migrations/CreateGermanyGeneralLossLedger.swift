import Fluent

struct CreateGermanyGeneralLossLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GermanyGeneralLossYear.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("tax_year", .int, .required)
            .field("net_capital_result", .double, .required)
            .field("loss_generated", .double, .required)
            .field("prior_loss_applied", .double, .required)
            .field("taxable_capital_gain", .double, .required)
            .field("ending_loss_carryforward", .double, .required)
            .field("rule_version", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "tax_year")
            .create()

        try await database.schema(GermanyGeneralLossApplication.schema)
            .id()
            .field(
                "source_year_id",
                .uuid,
                .required,
                .references(GermanyGeneralLossYear.schema, .id, onDelete: .cascade)
            )
            .field("target_tax_year", .int, .required)
            .field("amount", .double, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "source_year_id", "target_tax_year")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GermanyGeneralLossApplication.schema).delete()
        try await database.schema(GermanyGeneralLossYear.schema).delete()
    }
}
