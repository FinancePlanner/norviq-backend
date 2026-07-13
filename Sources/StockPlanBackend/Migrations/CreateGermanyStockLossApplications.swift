import Fluent

struct CreateGermanyStockLossApplications: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GermanyStockLossApplication.schema)
            .id()
            .field(
                "source_year_id",
                .uuid,
                .required,
                .references(GermanyStockLossYear.schema, .id, onDelete: .cascade)
            )
            .field("target_tax_year", .int, .required)
            .field("amount", .double, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "source_year_id", "target_tax_year")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GermanyStockLossApplication.schema).delete()
    }
}
