import Fluent

struct CreateResearchNote: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("research_notes")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("title", .string)
            .field("thesis", .string, .required)
            .field("risks", .string)
            .field("catalysts", .string)
            .field("reference_links", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "research_notes", columns: ["user_id", "symbol"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("research_notes").delete()
    }
}
