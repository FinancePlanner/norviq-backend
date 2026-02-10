import Fluent

struct CreateTarget: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("targets")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("scenario", .string, .required)
            .field("target_price", .double, .required)
            .field("target_date", .date)
            .field("rationale", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "targets", columns: ["user_id", "symbol"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("targets").delete()
    }
}
