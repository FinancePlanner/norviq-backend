import Fluent
import FluentSQL

struct CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .id()
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "email")
            .create()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP TABLE IF EXISTS users CASCADE").run()
            return
        }
        try await database.schema("users").delete()
    }
}
