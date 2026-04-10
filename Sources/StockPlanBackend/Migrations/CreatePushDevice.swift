import Fluent

struct CreatePushDevice: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PushDevice.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("device_token", .string, .required)
            .field("platform", .string, .required)
            .field("apns_environment", .string, .required)
            .field("authorization_status", .string, .required)
            .field("is_active", .bool, .required)
            .field("last_seen_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "device_token")
            .create()

        try await database.createIndex(on: PushDevice.schema, columns: ["user_id", "is_active"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PushDevice.schema).delete()
    }
}
