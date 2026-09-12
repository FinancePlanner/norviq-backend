import Fluent

struct CreatePortfolioValueSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("portfolio_value_snapshots")
            .id()
            .field("user_id", .uuid, .required)
            .field("portfolio_list_id", .uuid, .required)
            .field("captured_on", .date, .required)
            .field("currency", .string, .required)
            .field("market_value", .double, .required)
            .field("cost_basis", .double, .required)
            .field("cash_balance", .double, .required)
            .field("position_count", .int, .required)
            .field("source", .string, .required)
            .field("priced_symbols", .int, .required)
            .field("missing_symbols", .int, .required)
            .field("created_at", .datetime, .required)
            // Idempotency for the capture job: one row per portfolio per day,
            // however many times the job runs.
            .unique(on: "user_id", "portfolio_list_id", "captured_on")
            .create()

        // Reads are always "this portfolio, this window, in date order".
        try await database.createIndex(
            on: "portfolio_value_snapshots",
            columns: ["user_id", "portfolio_list_id", "captured_on"]
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("portfolio_value_snapshots").delete()
    }
}
