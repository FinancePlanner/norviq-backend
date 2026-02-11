import Fluent

struct CreateStatisticsSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("statistics_snapshots")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("as_of_date", .date, .required)
            .field("generated_at", .datetime, .required)
            .field("payload", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "kind", "as_of_date")
            .create()

        try await database.createIndex(
            on: "statistics_snapshots",
            columns: ["user_id", "kind", "generated_at"],
            name: "idx_statistics_snapshots_user_kind_generated_at"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("statistics_snapshots").delete()
    }
}
