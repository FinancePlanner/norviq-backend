import Fluent
import FluentSQL

struct CreateRatiosCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(RatiosCache.schema)
            .id()
            .field("provider", .string, .required)
            .field("symbol", .string, .required)
            .field("period", .string, .required)
            .field("limit", .int, .required)
            .field("payload", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "provider", "symbol", "period", "limit")
            .create()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        let schema = RatiosCache.schema
        try await sql.raw("DROP TABLE IF EXISTS \(raw: schema)").run()
    }
}
