import Fluent
import FluentSQL

struct CreatePersonalAccessTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("personal_access_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("scopes", .array(of: .string), .required)
            .field("last_used_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()

        try await database.createIndex(on: "personal_access_tokens", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("personal_access_tokens").delete()
    }
}
