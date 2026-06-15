import Fluent
import FluentSQL

struct CreateWebAuthnTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebAuthnCredential.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("credential_id", .string, .required)
            .field("public_key", .data, .required)
            .field("sign_count", .uint32, .required, .sql(.default(SQLRaw("0"))))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "credential_id")
            .create()

        try await database.schema(WebAuthnLoginChallenge.schema)
            .id()
            .field("challenge", .data, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .create()

        try await database.createIndex(
            on: WebAuthnCredential.schema,
            columns: ["user_id"],
            name: "idx_webauthn_credentials_user_id"
        )
        try await database.createIndex(
            on: WebAuthnLoginChallenge.schema,
            columns: ["expires_at"],
            name: "idx_webauthn_login_challenges_expires_at"
        )
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_webauthn_login_challenges_expires_at").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_webauthn_credentials_user_id").run()
        }
        try await database.schema(WebAuthnLoginChallenge.schema).delete()
        try await database.schema(WebAuthnCredential.schema).delete()
    }
}
