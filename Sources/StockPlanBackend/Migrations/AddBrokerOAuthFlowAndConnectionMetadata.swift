import Fluent

struct AddBrokerOAuthFlowAndConnectionMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("broker_connections")
            .field("display_name", .string)
            .field("status_detail", .string)
            .field("connected_at", .datetime)
            .field("last_synced_at", .datetime)
            .field("portfolio_list_id", .uuid)
            .update()

        try await database.schema(BrokerOAuthFlow.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("state", .string, .required)
            .field("redirect_uri", .string, .required)
            .field("portfolio_list_id", .uuid)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()

        try await database.createIndex(on: BrokerOAuthFlow.schema, columns: ["user_id"], name: "idx_broker_oauth_flows_user_id")
        try await database.createIndex(on: BrokerOAuthFlow.schema, columns: ["provider", "expires_at"], name: "idx_broker_oauth_flows_provider_expires_at")
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrokerOAuthFlow.schema).delete()
        try await database.schema("broker_connections")
            .deleteField("display_name")
            .deleteField("status_detail")
            .deleteField("connected_at")
            .deleteField("last_synced_at")
            .deleteField("portfolio_list_id")
            .update()
    }
}
