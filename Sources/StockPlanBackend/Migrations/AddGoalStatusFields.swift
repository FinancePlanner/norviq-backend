import Fluent
import FluentSQL

struct AddGoalStatusFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw(
            """
            ALTER TABLE goals
            ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'pending',
            ADD COLUMN IF NOT EXISTS status_updated_by TEXT,
            ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP
            """
        ).run()

        try await sql.raw(
            """
            UPDATE goals
            SET status_updated_by = 'manual'
            WHERE status_updated_by IS NULL
            """
        ).run()

        try await sql.raw(
            "ALTER TABLE goals ALTER COLUMN status DROP DEFAULT"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw(
            """
            ALTER TABLE goals
            DROP COLUMN IF EXISTS status,
            DROP COLUMN IF EXISTS status_updated_by,
            DROP COLUMN IF EXISTS completed_at
            """
        ).run()
    }
}
