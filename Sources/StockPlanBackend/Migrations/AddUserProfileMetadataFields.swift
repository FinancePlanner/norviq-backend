import Fluent

struct AddUserProfileMetadataFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("bio", .string)
            .field("avatar_url", .string)
            .field("banner_avatar_url", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("banner_avatar_url")
            .deleteField("avatar_url")
            .deleteField("bio")
            .update()
    }
}
