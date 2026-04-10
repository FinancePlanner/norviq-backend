import Fluent

struct AddAccountLockoutAndVerificationFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("failed_login_attempts", .int, .required, .custom("DEFAULT 0"))
            .field("lockout_until", .datetime)
            .field("is_verified", .bool, .required, .custom("DEFAULT false"))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("failed_login_attempts")
            .deleteField("lockout_until")
            .deleteField("is_verified")
            .update()
    }
}
