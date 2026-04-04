import Fluent

struct CreateCryptoPortfolioItem: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("crypto_portfolio_items")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("symbol", .string, .required)
            .field("name", .string, .required)
            .field("quantity", .double, .required)
            .field("average_buy_price", .double, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: "crypto_portfolio_items", columns: ["user_id", "symbol"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("crypto_portfolio_items").delete()
    }
}
