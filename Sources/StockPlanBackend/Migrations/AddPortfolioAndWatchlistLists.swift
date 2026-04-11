import Fluent
import FluentSQL
import Foundation
import Vapor

struct AddPortfolioAndWatchlistLists: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("portfolio_lists")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("is_default", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "name")
            .create()

        try await database.schema("watchlist_lists")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("is_default", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "name")
            .create()

        try await database.createIndex(
            on: "portfolio_lists",
            columns: ["user_id", "created_at"],
            name: "idx_portfolio_lists_user_id_created_at"
        )
        try await database.createIndex(
            on: "watchlist_lists",
            columns: ["user_id", "created_at"],
            name: "idx_watchlist_lists_user_id_created_at"
        )

        try await database.schema("stocks")
            .field(
                "portfolio_list_id",
                .uuid,
                .references("portfolio_lists", "id", onDelete: .restrict)
            )
            .update()

        try await database.schema("watchlist_items")
            .field(
                "watchlist_list_id",
                .uuid,
                .references("watchlist_lists", "id", onDelete: .restrict)
            )
            .update()

        let users = try await User.query(on: database).all()
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database is required for list backfill migration.")
        }

        for user in users {
            guard let userId = user.id else { continue }
            let portfolioListId = try await ensureDefaultPortfolioList(userId: userId, on: database)
            let watchlistListId = try await ensureDefaultWatchlistList(userId: userId, on: database)

            try await sql.raw(
                """
                UPDATE stocks
                SET portfolio_list_id = \(bind: portfolioListId)
                WHERE user_id = \(bind: userId)
                  AND portfolio_list_id IS NULL
                """
            ).run()

            try await sql.raw(
                """
                UPDATE watchlist_items
                SET watchlist_list_id = \(bind: watchlistListId)
                WHERE user_id = \(bind: userId)
                  AND watchlist_list_id IS NULL
                """
            ).run()
        }

        try await sql.raw("ALTER TABLE stocks ALTER COLUMN portfolio_list_id SET NOT NULL").run()
        try await sql.raw("ALTER TABLE watchlist_items ALTER COLUMN watchlist_list_id SET NOT NULL")
            .run()

        try await sql.raw("ALTER TABLE watchlist_items DROP CONSTRAINT IF EXISTS watchlist_items_user_id_symbol_key").run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_watchlist_items_user_list_symbol_unique
            ON watchlist_items (user_id, watchlist_list_id, symbol)
            """
        ).run()

        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_stocks_user_list_created_at
            ON stocks (user_id, portfolio_list_id, created_at)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_stocks_user_list_symbol
            ON stocks (user_id, portfolio_list_id, symbol)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_watchlist_items_user_list_created_at
            ON watchlist_items (user_id, watchlist_list_id, created_at)
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema("stocks")
                .deleteField("portfolio_list_id")
                .update()
            try await database.schema("watchlist_items")
                .deleteField("watchlist_list_id")
                .update()
            try await database.schema("portfolio_lists").delete()
            try await database.schema("watchlist_lists").delete()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS idx_watchlist_items_user_list_symbol_unique").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_stocks_user_list_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_stocks_user_list_symbol").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_watchlist_items_user_list_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_portfolio_lists_user_id_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_watchlist_lists_user_id_created_at").run()
        try await sql.raw(
            """
            DO $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1
                FROM pg_constraint
                WHERE conname = 'watchlist_items_user_id_symbol_key'
              ) THEN
                ALTER TABLE watchlist_items
                ADD CONSTRAINT watchlist_items_user_id_symbol_key UNIQUE (user_id, symbol);
              END IF;
            END $$;
            """
        ).run()

        try await database.schema("stocks")
            .deleteField("portfolio_list_id")
            .update()
        try await database.schema("watchlist_items")
            .deleteField("watchlist_list_id")
            .update()
        try await database.schema("portfolio_lists").delete()
        try await database.schema("watchlist_lists").delete()
    }

    private func ensureDefaultPortfolioList(userId: UUID, on db: any Database) async throws -> UUID {
        if let existing = try await PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$isDefault == true)
            .first(),
            let id = existing.id {
            return id
        }

        let created = PortfolioList(
            userId: userId,
            name: "Main Portfolio",
            isDefault: true
        )
        try await created.save(on: db)
        guard let id = created.id else {
            throw Abort(.internalServerError, reason: "Failed to create default portfolio list.")
        }
        return id
    }

    private func ensureDefaultWatchlistList(userId: UUID, on db: any Database) async throws -> UUID {
        if let existing = try await WatchlistList.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$isDefault == true)
            .first(),
            let id = existing.id {
            return id
        }

        let created = WatchlistList(
            userId: userId,
            name: "Main Watchlist",
            isDefault: true
        )
        try await created.save(on: db)
        guard let id = created.id else {
            throw Abort(.internalServerError, reason: "Failed to create default watchlist list.")
        }
        return id
    }
}
