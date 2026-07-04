import Fluent

struct CreateInsightEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("insight_events")
            .id()
            .field("dedupe_key", .string, .required)
            .field("source", .string, .required)
            .field("topic", .string, .required)
            .field("title", .string)
            .field("summary", .string)
            .field("sentiment_label", .string)
            .field("sentiment_score", .double)
            .field("source_url", .string)
            .field("author", .string)
            .field("observed_at", .datetime, .required)
            .field("raw_payload", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "dedupe_key")
            .create()

        try await database.createIndex(on: "insight_events", columns: ["topic"])
        try await database.createIndex(on: "insight_events", columns: ["topic", "observed_at"])
        try await database.createIndex(on: "insight_events", columns: ["observed_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("insight_events").delete()
    }
}
