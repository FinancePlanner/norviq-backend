import Fluent

struct AddImportSourceFieldsToStocks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("stocks")
            .field("source_provider", .string)
            .field("source_account_id", .uuid, .references("accounts", "id", onDelete: .setNull))
            .update()

        try await database.createIndex(on: "stocks", columns: ["user_id", "source_provider", "symbol"])
        try await database.createIndex(on: "stocks", columns: ["source_account_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("stocks")
            .deleteField("source_provider")
            .deleteField("source_account_id")
            .update()
    }
}
