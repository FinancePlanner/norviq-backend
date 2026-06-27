import Fluent
import FluentSQL

struct AddReferenceKeyToUserActivity: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_activities")
            .field("reference_key", .string)
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_user_activities_unique_reference
            ON user_activities (user_id, type, reference_key)
            WHERE reference_key IS NOT NULL
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_user_activities_unique_reference").run()
        }

        try await database.schema("user_activities")
            .deleteField("reference_key")
            .update()
    }
}
