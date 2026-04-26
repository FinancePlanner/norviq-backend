import Fluent
import FluentSQL

struct CreateWebhookDeliveries: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create the enum type for status
        let statusEnum = try await database.enum("webhook_delivery_status")
            .case("pending")
            .case("success")
            .case("failed")
            .case("exhausted")
            .create()

        // Create the table
        try await database.schema("webhook_deliveries")
            .id()
            .field("webhook_key", .string, .required)
            .field("url", .string, .required)
            .field("method", .string, .required)
            .field("headers", .json)
            .field("payload", .data)
            .field("attempt_count", .int, .required, .sql(.default(0)))
            .field("next_retry_at", .datetime)
            .field("last_error", .string)
            .field("status", statusEnum, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        // Indexes
        try await database.createIndex(on: "webhook_deliveries", columns: ["webhook_key"])
        try await database.createIndex(on: "webhook_deliveries", columns: ["status", "next_retry_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("webhook_deliveries").delete()
        try await database.enum("webhook_delivery_status").delete()
    }
}
