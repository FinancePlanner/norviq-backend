import Fluent
import FluentSQL

struct AddDatabaseOptimizations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 1. Authentication & Profile Lookups
        try await database.createIndex(
            on: "users",
            columns: ["username"],
            name: "idx_users_username"
        )

        try await database.createIndex(
            on: "password_reset_tokens",
            columns: ["code_hash"],
            name: "idx_password_reset_tokens_code_hash"
        )

        // 3. Market Data Search
        try await database.createIndex(
            on: "search_cache",
            columns: ["normalized_query"],
            name: "idx_search_cache_normalized_query"
        )
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_users_username").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_password_reset_tokens_code_hash").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_search_cache_normalized_query").run()
    }
}
