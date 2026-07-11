import Fluent

struct CreateHoldingRiskProfiles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HoldingRiskProfileModel.schema)
            .id().field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("holding_id", .uuid, .required, .references("stocks", "id", onDelete: .cascade))
            .field("asset_category", .string, .required).field("sector", .string).field("region", .string)
            .field("benchmark_proxy", .string).field("manual_value", .double).field("duration", .double)
            .field("convexity", .double).field("factor_overrides", .json, .required)
            .field("created_at", .datetime).field("updated_at", .datetime).create()
        try await database.createIndex(on: HoldingRiskProfileModel.schema, columns: ["user_id", "holding_id"], unique: true)
        try await database.createIndex(on: HoldingRiskProfileModel.schema, columns: ["benchmark_proxy"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HoldingRiskProfileModel.schema).delete()
    }
}
