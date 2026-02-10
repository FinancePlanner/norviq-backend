import Fluent

struct CreateBrokerConnection: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("broker_connections")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("external_id", .string)
            .field("access_token", .string)
            .field("refresh_token", .string)
            .field("expires_at", .datetime)
            .field("status", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "provider")
            .create()

        try await database.createIndex(on: "broker_connections", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("broker_connections").delete()
    }
}
