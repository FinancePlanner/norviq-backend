import Fluent
import FluentSQL

struct AddOAuthFlowPurposeAndUserID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OAuthFlow.schema)
            .field("purpose", .string, .required, .sql(.default(SQLRaw("'login'"))))
            .field("user_id", .uuid, .references(User.schema, .id, onDelete: .cascade))
            .update()

        try await database.createIndex(
            on: OAuthFlow.schema,
            columns: ["user_id"],
            name: "idx_oauth_flows_user_id"
        )
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(OAuthFlow.schema)
                .deleteField("user_id")
                .deleteField("purpose")
                .update()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS idx_oauth_flows_user_id").run()
        try await database.schema(OAuthFlow.schema)
            .deleteField("user_id")
            .deleteField("purpose")
            .update()
    }
}
