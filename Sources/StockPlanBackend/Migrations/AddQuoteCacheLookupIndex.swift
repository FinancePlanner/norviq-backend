import Fluent
import FluentSQL

struct AddQuoteCacheLookupIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.createIndex(
            on: "quote_cache",
            columns: ["symbol", "as_of"],
            name: "idx_quote_cache_symbol_as_of"
        )
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_quote_cache_symbol_as_of").run()
    }
}
