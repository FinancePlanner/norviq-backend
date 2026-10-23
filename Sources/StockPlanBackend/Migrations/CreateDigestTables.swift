import Fluent

/// Weekly digest ("Your money, explained") and sentiment alerts.
///
/// - `digest_preferences`: one row per user once they have decided. No row
///   means "never asked", which is what shows the opt-in card.
/// - `weekly_digests`: one per (user, period). The unique key is the claim:
///   a rerun or a second replica cannot compose the same week twice.
/// - `weekly_digest_deliveries`: one per (digest, channel), inserted before
///   sending, so a crash mid-send costs a missed message, never a duplicate.
/// - `sentiment_alerts`: one row per alert sent; the cooldown index reads it.
struct CreateDigestTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DigestPreference.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("email_enabled", .bool, .required)
            .field("push_enabled", .bool, .required)
            .field("telegram_enabled", .bool, .required)
            .field("sentiment_alerts_enabled", .bool, .required)
            .field("weekday", .int, .required)
            .field("local_hour", .int, .required)
            .field("timezone", .string, .required)
            .field("country", .string)
            .field("unsubscribe_token", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .unique(on: "unsubscribe_token")
            .create()

        try await database.schema(WeeklyDigest.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("period_start", .string, .required)
            .field("period_end", .string, .required)
            .field("status", .string, .required)
            .field("payload", .string)
            .field("narrative", .string)
            .field("model", .string)
            .field("token_count", .int)
            .field("error", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "period_start")
            .create()

        try await database.schema(WeeklyDigestDelivery.schema)
            .id()
            .field("digest_id", .uuid, .required, .references(WeeklyDigest.schema, "id", onDelete: .cascade))
            .field("channel", .string, .required)
            .field("status", .string, .required)
            .field("error", .string)
            .field("sent_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "digest_id", "channel")
            .create()

        try await database.schema("sentiment_alerts")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("score_before", .double, .required)
            .field("score_after", .double, .required)
            .field("volume_ratio", .double, .required)
            .field("sent_at", .datetime, .required)
            .create()

        try await database.createIndex(on: "sentiment_alerts", columns: ["user_id", "symbol", "sent_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sentiment_alerts").delete()
        try await database.schema(WeeklyDigestDelivery.schema).delete()
        try await database.schema(WeeklyDigest.schema).delete()
        try await database.schema(DigestPreference.schema).delete()
    }
}
