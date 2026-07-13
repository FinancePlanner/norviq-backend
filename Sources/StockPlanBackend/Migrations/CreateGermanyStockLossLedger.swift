import Fluent

struct CreateGermanyStockLossLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GermanyStockLossYear.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("tax_year", .int, .required)
            .field("net_stock_result", .double, .required)
            .field("loss_generated", .double, .required)
            .field("prior_loss_applied", .double, .required)
            .field("taxable_stock_gain", .double, .required)
            .field("ending_loss_carryforward", .double, .required)
            .field("rule_version", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "tax_year")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GermanyStockLossYear.schema).delete()
    }
}
