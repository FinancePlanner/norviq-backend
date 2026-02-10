import Fluent
import FluentSQL

struct CreatePasswordResetToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("password_reset_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime, .required)
            .create()
        
        // Create indexes using the Database extension
        try await database.createIndex(on: "password_reset_tokens", columns: ["user_id"])
        try await database.createIndex(on: "password_reset_tokens", columns: ["expires_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("password_reset_tokens").delete()
    }
}
