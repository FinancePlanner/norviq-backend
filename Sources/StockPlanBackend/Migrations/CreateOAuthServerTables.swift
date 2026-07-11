import Fluent
import FluentSQL

struct CreateOAuthServerTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_clients")
            .id()
            .field("client_id", .string, .required)
            .field("client_name", .string, .required)
            .field("redirect_uris", .array(of: .string), .required)
            .field("token_endpoint_auth_method", .string, .required)
            .field("last_used_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "client_id")
            .create()

        try await database.schema("oauth_authorization_flows")
            .id()
            .field("client_id", .string, .required)
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("scopes", .array(of: .string), .required)
            .field("redirect_uri", .string, .required)
            .field("state", .string)
            .field("code_challenge", .string, .required)
            .field("code_hash", .string)
            .field("status", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .create()
        try await database.createIndex(on: "oauth_authorization_flows", columns: ["code_hash"])

        try await database.schema("oauth_tokens")
            .id()
            .field("client_id", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("access_token_hash", .string, .required)
            .field("refresh_token_hash", .string, .required)
            .field("scopes", .array(of: .string), .required)
            .field("access_expires_at", .datetime, .required)
            .field("refresh_expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("replaced_by", .uuid)
            .field("created_at", .datetime, .required)
            .unique(on: "access_token_hash")
            .unique(on: "refresh_token_hash")
            .create()
        try await database.createIndex(on: "oauth_tokens", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_tokens").delete()
        try await database.schema("oauth_authorization_flows").delete()
        try await database.schema("oauth_clients").delete()
    }
}
