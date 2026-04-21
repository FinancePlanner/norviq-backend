import Fluent

struct AddTrialFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("trial_started_at", .datetime)
            .field("trial_days", .int)
            .field("trial_tier", .string)
            .field("trial_warning_sent_at", .datetime)
            .field("had_trial", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("trial_started_at")
            .deleteField("trial_days")
            .deleteField("trial_tier")
            .deleteField("trial_warning_sent_at")
            .deleteField("had_trial")
            .update()
    }
}
