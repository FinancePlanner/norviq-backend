import Fluent

struct AddAssetCategoryToStocks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create the enum type first
        let categoryEnum = try await database.enum("asset_category")
            .case("stock")
            .case("etf")
            .case("crypto")
            .create()

        try await database.schema("stocks")
            .field("category", categoryEnum, .required, .custom("DEFAULT 'stock'"))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("stocks")
            .deleteField("category")
            .update()

        try await database.enum("asset_category").delete()
    }
}
