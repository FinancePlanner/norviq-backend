import Fluent
import SQLKit

/// Account deletion must take the user's rows with it.
///
/// * `feedbacks.user_id` referenced `users` with no ON DELETE, so deleting a
///   user who had ever sent feedback failed on the constraint.
/// * `portfolio_value_snapshots` and `tax_loss_carryforwards` had no foreign
///   key at all, so their rows outlived the account. Orphans already left
///   behind are deleted before the constraint goes on.
///
/// The feedback constraint was created inline, so Postgres named it; it is
/// looked up rather than assumed. Everything runs in one transaction, and each
/// ADD is preceded by a DROP IF EXISTS, so a half-applied or repeated run
/// cannot leave a table without its key or fail on a duplicate.
struct CascadeUserOwnedRowsOnDelete: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else { return }

            try await Self.dropUserForeignKeys(on: "feedbacks", sql: sql)
            try await sql.raw("""
            ALTER TABLE feedbacks ADD CONSTRAINT feedbacks_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
            """).run()

            for table in ["portfolio_value_snapshots", "tax_loss_carryforwards"] {
                try await sql.raw("""
                DELETE FROM \(unsafeRaw: table) t
                WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.user_id)
                """).run()
                try await sql.raw("""
                ALTER TABLE \(unsafeRaw: table) DROP CONSTRAINT IF EXISTS \(unsafeRaw: table)_user_id_fkey
                """).run()
                try await sql.raw("""
                ALTER TABLE \(unsafeRaw: table) ADD CONSTRAINT \(unsafeRaw: table)_user_id_fkey
                FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
                """).run()
            }
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for table in ["portfolio_value_snapshots", "tax_loss_carryforwards"] {
            try await sql.raw("""
            ALTER TABLE \(unsafeRaw: table) DROP CONSTRAINT IF EXISTS \(unsafeRaw: table)_user_id_fkey
            """).run()
        }
        try await Self.dropUserForeignKeys(on: "feedbacks", sql: sql)
        try await sql.raw("""
        ALTER TABLE feedbacks ADD CONSTRAINT feedbacks_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id)
        """).run()
    }

    /// Drops every foreign key from `table` (in the current schema) to `users`.
    private static func dropUserForeignKeys(on table: String, sql: any SQLDatabase) async throws {
        try await sql.raw("""
        DO $$
        DECLARE fk record;
        BEGIN
            FOR fk IN
                SELECT con.conname
                FROM pg_constraint con
                JOIN pg_class rel ON rel.oid = con.conrelid
                JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
                WHERE con.contype = 'f'
                  AND rel.relname = '\(unsafeRaw: table)'
                  AND nsp.nspname = current_schema()
                  AND con.confrelid = 'users'::regclass
            LOOP
                EXECUTE format('ALTER TABLE \(unsafeRaw: table) DROP CONSTRAINT %I', fk.conname);
            END LOOP;
        END $$
        """).run()
    }
}
