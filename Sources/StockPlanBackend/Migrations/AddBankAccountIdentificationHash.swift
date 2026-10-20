import Fluent

struct AddBankAccountIdentificationHash: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BankAccount.schema)
            .field("identification_hash", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BankAccount.schema)
            .deleteField("identification_hash")
            .update()
    }
}
