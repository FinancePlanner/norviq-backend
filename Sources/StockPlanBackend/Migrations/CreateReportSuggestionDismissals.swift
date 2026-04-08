import Fluent

struct CreateReportSuggestionDismissals: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ReportSuggestionDismissal.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("suggestion_id", .string, .required)
            .field("dismissed_at", .datetime, .required)
            .unique(on: "user_id", "suggestion_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ReportSuggestionDismissal.schema).delete()
    }
}
