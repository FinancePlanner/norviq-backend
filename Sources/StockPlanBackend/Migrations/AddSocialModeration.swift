import Fluent

/// Report review state and moderator suspensions (App Review Guideline 1.2:
/// act on reports within 24 hours and remove offending users).
struct AddSocialModeration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("social_reports")
            .field("resolution", .string)
            .field("resolution_note", .string)
            .field("resolved_by", .uuid)
            .field("resolved_at", .datetime)
            .update()
        try await database.schema("social_settings")
            .field("suspended_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("social_settings").deleteField("suspended_at").update()
        try await database.schema("social_reports")
            .deleteField("resolution")
            .deleteField("resolution_note")
            .deleteField("resolved_by")
            .deleteField("resolved_at")
            .update()
    }
}
