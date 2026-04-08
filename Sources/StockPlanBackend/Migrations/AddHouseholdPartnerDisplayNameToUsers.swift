import Fluent

struct AddHouseholdPartnerDisplayNameToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("household_partner_display_name", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("household_partner_display_name")
            .update()
    }
}
