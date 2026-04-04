import Fluent

struct CreateFeedback: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("feedbacks")
            .id()
            .field("topic", .string, .required)
            .field("message", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("feedbacks").delete()
    }
}
