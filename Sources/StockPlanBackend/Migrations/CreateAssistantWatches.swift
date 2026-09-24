import Fluent
import FluentSQL

/// Standing tasks ("watch X and ping me when Y", "every morning check …") and
/// the columns that let an assistant message say it was posted proactively.
///
/// Purely additive: a new table plus two nullable columns on `ai_messages`, so
/// a server one version behind keeps reading and writing messages unchanged.
struct CreateAssistantWatches: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AIAssistantWatch.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            // Cascade: deleting a thread deletes the tasks that post into it.
            // A running watch bumps its thread's expiry, so retention does not
            // retire a thread out from under a live task.
            .field("conversation_id", .uuid, .required, .references(AIConversation.schema, "id", onDelete: .cascade))
            .field("title_encrypted", .data, .required)
            .field("spec_encrypted", .data, .required)
            // Present for "… when Y" watches: those report only when Y holds,
            // then switch themselves off. Absent for scheduled reports.
            .field("condition_encrypted", .data)
            .field("schedule_human", .string, .required)
            .field("interval_minutes", .int, .required)
            .field("next_run_at", .datetime, .required)
            .field("last_run_at", .datetime)
            .field("enabled", .bool, .required, .sql(.default(true)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        // The job's claim query is `enabled AND next_run_at <= now()`.
        try await sql.raw("""
        CREATE INDEX assistant_watches_due_idx ON assistant_watches (next_run_at) WHERE enabled
        """).run()
        try await sql.raw("CREATE INDEX assistant_watches_user_idx ON assistant_watches (user_id)").run()

        try await database.schema(AIAssistantMessage.schema)
            .field("origin", .string)
            .field("source_label", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AIAssistantMessage.schema)
            .deleteField("origin")
            .deleteField("source_label")
            .update()
        try await database.schema(AIAssistantWatch.schema).delete()
    }
}
