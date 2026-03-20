import Fluent
import FluentSQL

struct AddWatchlistMetadataFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw(
            """
            ALTER TABLE watchlist_items
            ADD COLUMN IF NOT EXISTS note TEXT,
            ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active',
            ADD COLUMN IF NOT EXISTS last_reviewed_at TIMESTAMP,
            ADD COLUMN IF NOT EXISTS next_review_at TIMESTAMP
            """
        ).run()

        try await sql.raw(
            "ALTER TABLE watchlist_items ALTER COLUMN status DROP DEFAULT"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw(
            """
            ALTER TABLE watchlist_items
            DROP COLUMN IF EXISTS note,
            DROP COLUMN IF EXISTS status,
            DROP COLUMN IF EXISTS last_reviewed_at,
            DROP COLUMN IF EXISTS next_review_at
            """
        ).run()
    }
}
