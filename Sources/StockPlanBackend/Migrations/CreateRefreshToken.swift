import Fluent
import FluentSQL

struct CreateRefreshToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("refresh_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
        
        // Create indexes using the Database extension
        try await database.createIndex(on: "refresh_tokens", columns: ["user_id"])
        try await database.createIndex(on: "refresh_tokens", columns: ["expires_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("refresh_tokens").delete()
    }
}
