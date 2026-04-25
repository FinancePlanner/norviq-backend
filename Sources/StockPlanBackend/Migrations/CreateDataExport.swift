import Fluent

struct CreateDataExport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("data_exports")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("type", .string, .required)
            .field("format", .string, .required)
            .field("filters", .json)
            .field("status", .string, .required)
            .field("file_path", .string)
            .field("file_size_bytes", .int64)
            .field("expires_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("data_exports").delete()
    }
}
