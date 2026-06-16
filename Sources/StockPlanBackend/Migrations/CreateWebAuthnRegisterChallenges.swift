import Fluent
import FluentSQL

struct CreateWebAuthnRegisterChallenges: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebAuthnRegisterChallenge.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("challenge", .data, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .create()

        try await database.createIndex(
            on: WebAuthnRegisterChallenge.schema,
            columns: ["expires_at"],
            name: "idx_webauthn_register_challenges_expires_at"
        )
        try await database.createIndex(
            on: WebAuthnRegisterChallenge.schema,
            columns: ["user_id"],
            name: "idx_webauthn_register_challenges_user_id"
        )
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_webauthn_register_challenges_user_id").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_webauthn_register_challenges_expires_at").run()
        }
        try await database.schema(WebAuthnRegisterChallenge.schema).delete()
    }
}
