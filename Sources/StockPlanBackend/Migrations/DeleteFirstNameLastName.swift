import Fluent

struct DeleteFirstNameLastName: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("first_name")
            .deleteField("last_name")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .field("first_name", .string)
            .field("last_name", .string)
            .update()
    }
}
