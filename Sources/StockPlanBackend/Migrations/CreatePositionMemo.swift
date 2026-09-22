import Fluent
import FluentSQL

struct CreatePositionMemo: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PositionMemo.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("conversation_id", .uuid)
            .field("asked_symbol", .string, .required)
            .field("primary_symbol", .string, .required)
            .field("title_encrypted", .data, .required)
            .field("mark_encrypted", .data, .required)
            .field("sections_encrypted", .data, .required)
            .field("verdict_encrypted", .data, .required)
            .field("sources_encrypted", .data, .required)
            .field("evidence_encrypted", .data, .required)
            .field("bookmarked", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .create()
        try await database.createIndex(on: PositionMemo.schema, columns: ["user_id", "bookmarked"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PositionMemo.schema).delete()
    }
}
