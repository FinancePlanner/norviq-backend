import Fluent
import FluentSQL

struct CreateBasicFinancialsCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BasicFinancialsCache.schema)
            .id()
            .field("provider", .string, .required)
            .field("symbol", .string, .required)
            .field("payload", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "provider", "symbol")
            .create()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        let schema = BasicFinancialsCache.schema
        try await sql.raw("DROP TABLE IF EXISTS \(raw: schema)").run()
    }
}
