import Fluent

struct CreateStatisticsSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("statistics_snapshots")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("as_of_date", .date, .required)
            .field("generated_at", .datetime, .required)
            .field("total_market_value", .double, .required)
            .field("total_cost_basis", .double, .required)
            .field("total_unrealized_pnl", .double, .required)
            .field("total_realized_pnl", .double, .required)
            .field("payload", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "as_of_date")
            .create()

        try await database.createIndex(
            on: "statistics_snapshots",
            columns: ["user_id", "generated_at"],
            name: "idx_statistics_snapshots_user_generated_at"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("statistics_snapshots").delete()
    }
}
