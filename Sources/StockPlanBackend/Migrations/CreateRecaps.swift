import Fluent

/// One generated recap per (user, period). The unique key is also what keeps
/// two concurrent first opens from both writing a deck.
struct CreateRecaps: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("recaps")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("period_kind", .string, .required)
            .field("period_key", .string, .required)
            .field("payload", .string, .required)
            .field("archetype", .string)
            .field("schema_version", .int, .required)
            .field("generated_at", .datetime, .required)
            .field("opened_at", .datetime)
            .field("completed_at", .datetime)
            .unique(on: "user_id", "period_kind", "period_key")
            .create()

        try await database.createIndex(on: "recaps", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("recaps").delete()
    }
}
