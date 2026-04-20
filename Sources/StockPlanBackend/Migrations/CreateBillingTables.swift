import Fluent
import FluentSQL

struct CreateBillingTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Subscription.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("provider_customer_id", .string, .required)
            .field("provider_original_transaction_id", .string, .required)
            .field("product_id", .string, .required)
            .field("plan", .string, .required)
            .field("status", .string, .required)
            .field("period_started_at", .datetime)
            .field("period_ends_at", .datetime)
            .field("trial_ends_at", .datetime)
            .field("grace_period_ends_at", .datetime)
            .field("cancelled_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "provider", "provider_original_transaction_id")
            .create()

        try await database.schema(Entitlement.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("level", .string, .required)
            .field("subscription_id", .uuid, .references(Subscription.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()

        try await database.schema(BillingEvent.schema)
            .id()
            .field("provider", .string, .required)
            .field("provider_event_id", .string, .required)
            .field("user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("event_type", .string, .required)
            .field("raw_payload", .string, .required)
            .field("processed_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "provider_event_id")
            .create()

        try await database.schema(UsageCounter.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("period_start", .datetime, .required)
            .field("holding_count", .int, .required)
            .field("watchlist_item_count", .int, .required)
            .field("csv_import_count", .int, .required)
            .field("target_alert_count", .int, .required)
            .field("report_generation_count", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()

        try await database.createIndex(on: Subscription.schema, columns: ["user_id"])
        try await database.createIndex(on: Subscription.schema, columns: ["provider", "provider_original_transaction_id"])
        try await database.createIndex(on: Entitlement.schema, columns: ["user_id"])
        try await database.createIndex(on: BillingEvent.schema, columns: ["user_id"])
        try await database.createIndex(on: UsageCounter.schema, columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UsageCounter.schema).delete()
        try await database.schema(BillingEvent.schema).delete()
        try await database.schema(Entitlement.schema).delete()
        try await database.schema(Subscription.schema).delete()
    }
}
