import Fluent

struct AddUserProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("username", .string)
            .field("first_name", .string)
            .field("last_name", .string)
            .field("date_of_birth", .datetime)
            .unique(on: "username")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("date_of_birth")
            .deleteField("last_name")
            .deleteField("first_name")
            .deleteField("username")
            .update()
    }
}
