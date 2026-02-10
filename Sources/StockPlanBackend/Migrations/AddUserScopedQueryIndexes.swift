import Fluent
import FluentSQL

struct AddUserScopedQueryIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.createIndex(
            on: "stocks",
            columns: ["user_id", "created_at"],
            name: "idx_stocks_user_id_created_at"
        )
        try await database.createIndex(
            on: "watchlist_items",
            columns: ["user_id", "created_at"],
            name: "idx_watchlist_items_user_id_created_at"
        )
        try await database.createIndex(
            on: "research_notes",
            columns: ["user_id", "updated_at"],
            name: "idx_research_notes_user_id_updated_at"
        )
        try await database.createIndex(
            on: "targets",
            columns: ["user_id", "updated_at"],
            name: "idx_targets_user_id_updated_at"
        )
        try await database.createIndex(
            on: "broker_connections",
            columns: ["user_id", "updated_at"],
            name: "idx_broker_connections_user_id_updated_at"
        )
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_stocks_user_id_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_watchlist_items_user_id_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_research_notes_user_id_updated_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_targets_user_id_updated_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_broker_connections_user_id_updated_at").run()
    }
}
