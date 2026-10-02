import Fluent
import FluentSQL

/// Every guard on a portfolio or watchlist write, and default-list resolution,
/// looks up follows by target list. The existing unique index leads with
/// user_id, so those lookups scanned the table.
struct AddPilotFollowTargetIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_pilot_follows_portfolio_list_id ON pilot_follows (portfolio_list_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_pilot_follows_watchlist_list_id ON pilot_follows (watchlist_list_id)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_pilot_follows_watchlist_list_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_pilot_follows_portfolio_list_id").run()
    }
}
