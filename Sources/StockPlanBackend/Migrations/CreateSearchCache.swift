import Fluent

struct CreateSearchCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("search_cache")
            .id()
            .field("provider", .string, .required)
            .field("normalized_query", .string, .required)
            .field("payload", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "provider", "normalized_query")
            .create()

        try await database.createIndex(
            on: "search_cache",
            columns: ["provider", "normalized_query", "updated_at"],
            name: "idx_search_cache_provider_query_updated_at"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("search_cache").delete()
    }
}
