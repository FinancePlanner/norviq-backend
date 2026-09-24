import Fluent

struct CreatePortfolioShareLinks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("portfolio_share_links")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            // Deleting a portfolio deletes the links that expose it.
            .field("portfolio_list_id", .uuid, .references("portfolio_lists", "id", onDelete: .cascade))
            .field("slug", .string, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "slug")
            .create()

        try await database.createIndex(on: "portfolio_share_links", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("portfolio_share_links").delete()
    }
}
