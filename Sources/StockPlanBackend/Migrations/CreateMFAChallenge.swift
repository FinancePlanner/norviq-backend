import Fluent
import FluentSQL

struct CreateMFAChallenge: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MFAChallenge.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("purpose", .string, .required)
            .field("channel", .string, .required)
            .field("destination", .string, .required)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .field("failed_attempts", .int, .required)
            .field("resend_count", .int, .required)
            .field("last_sent_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: MFAChallenge.schema, columns: ["user_id"])
        try await database.createIndex(on: MFAChallenge.schema, columns: ["expires_at"])
        try await database.createIndex(on: MFAChallenge.schema, columns: ["user_id", "purpose", "consumed_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MFAChallenge.schema).delete()
    }
}
