import Fluent

struct CreateBankLinkFlow: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("bank_link_flows")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("reference", .string, .required)
            .field("requisition_id", .string, .required)
            .field("institution_id", .string)
            .field("app_redirect_uri", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "reference")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("bank_link_flows").delete()
    }
}
