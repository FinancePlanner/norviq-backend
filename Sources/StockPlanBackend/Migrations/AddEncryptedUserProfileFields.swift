import Fluent

struct AddEncryptedUserProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("date_of_birth_encrypted", .data)
            .field("bio_encrypted", .data)
            .field("household_partner_display_name_encrypted", .data)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("household_partner_display_name_encrypted")
            .deleteField("bio_encrypted")
            .deleteField("date_of_birth_encrypted")
            .update()
    }
}
