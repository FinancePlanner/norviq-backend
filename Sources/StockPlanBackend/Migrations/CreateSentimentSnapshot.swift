import Fluent

struct CreateSentimentSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("sentiment_snapshots")
            .id()
            .field("dedupe_key", .string, .required)
            .field("scope", .string, .required)
            .field("scope_key", .string)
            .field("window_days", .int, .required)
            .field("average_score", .double, .required)
            .field("label", .string, .required)
            .field("event_count", .int, .required)
            .field("positive_count", .int, .required)
            .field("neutral_count", .int, .required)
            .field("negative_count", .int, .required)
            .field("captured_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "dedupe_key")
            .create()

        try await database.createIndex(on: "sentiment_snapshots", columns: ["scope", "captured_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sentiment_snapshots").delete()
    }
}
