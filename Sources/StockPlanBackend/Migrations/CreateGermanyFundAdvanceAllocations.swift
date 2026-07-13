import Fluent

struct CreateGermanyFundAdvanceAllocations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GermanyFundAdvanceAllocation.schema)
            .id()
            .field(
                "annual_holding_id",
                .uuid,
                .required,
                .references(GermanyFundAnnualHolding.schema, .id, onDelete: .cascade)
            )
            .field(
                "disposal_id",
                .uuid,
                .required,
                .references(LotDisposal.schema, .id, onDelete: .cascade)
            )
            .field("quantity", .double, .required)
            .field("gross_advance_amount", .double, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "annual_holding_id", "disposal_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GermanyFundAdvanceAllocation.schema).delete()
    }
}
