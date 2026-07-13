import Fluent

struct CreateGermanyFundAnnualHoldings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GermanyFundAnnualHolding.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
            .field("instrument_id", .uuid, .required, .references(Instrument.schema, .id, onDelete: .cascade))
            .field("calculation_year", .int, .required)
            .field("client_holding_id", .string, .required)
            .field("lot_id", .uuid, .references(Lot.schema, .id, onDelete: .setNull))
            .field("quantity", .double)
            .field("remaining_quantity", .double)
            .field("currency", .string, .required)
            .field("beginning_market_value", .double, .required)
            .field("ending_market_value", .double, .required)
            .field("distributions", .double, .required)
            .field("acquisition_month", .int)
            .field("fund_classification", .string, .required)
            .field("basis_rate", .double, .required)
            .field("gross_advance_lump_sum", .double, .required)
            .field("remaining_gross_advance", .double, .required)
            .field("taxable_advance_lump_sum", .double, .required)
            .field("rule_version", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "account_id", "instrument_id", "calculation_year", "client_holding_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GermanyFundAnnualHolding.schema).delete()
    }
}
