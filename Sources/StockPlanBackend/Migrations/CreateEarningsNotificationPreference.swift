import Fluent

struct CreateEarningsNotificationPreference: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(EarningsNotificationPreference.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("enabled", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EarningsNotificationPreference.schema).delete()
    }
}
