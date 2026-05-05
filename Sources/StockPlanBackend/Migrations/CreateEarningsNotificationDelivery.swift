import Fluent

struct CreateEarningsNotificationDelivery: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(EarningsNotificationDelivery.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("earnings_date", .string, .required)
            .field("lead_days", .int, .required)
            .field("sent_at", .datetime, .required)
            .unique(on: "user_id", "symbol", "earnings_date", "lead_days")
            .create()

        try await database.createIndex(
            on: EarningsNotificationDelivery.schema,
            columns: ["user_id", "earnings_date"]
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EarningsNotificationDelivery.schema).delete()
    }
}
