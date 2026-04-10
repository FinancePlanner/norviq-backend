import Fluent

/// Final cleanup migration for the staged rollout.
/// Keep this migration unregistered until all environments complete encrypted backfill
/// and runtime reads no longer depend on plaintext fallback.
struct DropLegacyPlaintextUserProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("household_partner_display_name")
            .deleteField("bio")
            .deleteField("date_of_birth")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("date_of_birth", .datetime)
            .field("bio", .string)
            .field("household_partner_display_name", .string)
            .update()
    }
}
