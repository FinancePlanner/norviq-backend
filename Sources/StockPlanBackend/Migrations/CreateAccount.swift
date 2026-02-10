import Fluent

struct CreateAccount: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("accounts")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("external_id", .string, .required)
            .field("broker", .string, .required)
            .field("display_name", .string)
            .field("base_currency", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "broker", "external_id")
            .create()

        try await database.createIndex(on: "accounts", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("accounts").delete()
    }
}
