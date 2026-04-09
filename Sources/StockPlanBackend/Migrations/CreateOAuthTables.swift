import Fluent
import FluentSQL

struct CreateOAuthTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OAuthIdentity.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("provider", .string, .required)
            .field("provider_user_id", .string, .required)
            .field("email", .string)
            .field("email_verified", .bool, .required, .sql(.default(SQLRaw("false"))))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "provider", "provider_user_id")
            .create()

        try await database.schema(OAuthFlow.schema)
            .id()
            .field("provider", .string, .required)
            .field("state", .string, .required)
            .field("nonce", .string, .required)
            .field("code_verifier", .string, .required)
            .field("redirect_uri", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "state")
            .create()

        try await database.createIndex(on: OAuthIdentity.schema, columns: ["user_id"], name: "idx_oauth_identities_user_id")
        try await database.createIndex(on: OAuthFlow.schema, columns: ["provider", "expires_at"], name: "idx_oauth_flows_provider_expires_at")
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(OAuthFlow.schema).delete()
            try await database.schema(OAuthIdentity.schema).delete()
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS idx_oauth_flows_provider_expires_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_oauth_identities_user_id").run()
        try await database.schema(OAuthFlow.schema).delete()
        try await database.schema(OAuthIdentity.schema).delete()
    }
}
