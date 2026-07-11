import Fluent

struct CreateScenarioPlanningTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FinancialGoalModel.schema)
            .id().field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("portfolio_list_id", .uuid, .required, .references("portfolio_lists", "id", onDelete: .cascade))
            .field("name", .string, .required).field("target_amount", .double, .required)
            .field("target_date", .datetime, .required).field("base_currency", .string, .required)
            .field("monthly_contribution", .double, .required).field("annual_contribution_growth", .double, .required)
            .field("inflation_assumption", .double, .required).field("created_at", .datetime)
            .field("updated_at", .datetime).create()

        try await database.schema(ScenarioDefinitionModel.schema)
            .id().field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("portfolio_list_id", .uuid, .required, .references("portfolio_lists", "id", onDelete: .cascade))
            .field("financial_goal_id", .uuid, .references(FinancialGoalModel.schema, "id", onDelete: .setNull))
            .field("name", .string, .required).field("kind", .string, .required)
            .field("configuration", .json, .required).field("is_saved", .bool, .required)
            .field("created_at", .datetime).field("updated_at", .datetime).create()

        try await database.schema(ScenarioSnapshotModel.schema)
            .id().field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("portfolio_list_id", .uuid, .required, .references("portfolio_lists", "id", onDelete: .cascade))
            .field("base_currency", .string, .required).field("valuation_timestamp", .datetime, .required)
            .field("payload", .json, .required).field("warnings", .json, .required)
            .field("created_at", .datetime).create()

        try await database.schema(ScenarioRunModel.schema)
            .id().field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("scenario_id", .uuid, .required, .references(ScenarioDefinitionModel.schema, "id", onDelete: .cascade))
            .field("snapshot_id", .uuid, .required, .references(ScenarioSnapshotModel.schema, "id", onDelete: .restrict))
            .field("state", .string, .required).field("progress", .double, .required)
            .field("seed", .string, .required).field("deduplication_hash", .string, .required)
            .field("engine_version", .string, .required).field("catalog_version", .string, .required)
            .field("result", .json).field("error_message", .string).field("lease_owner", .string)
            .field("lease_expires_at", .datetime).field("created_at", .datetime).field("started_at", .datetime)
            .field("completed_at", .datetime).field("expires_at", .datetime).create()

        try await database.createIndex(on: FinancialGoalModel.schema, columns: ["user_id"])
        try await database.createIndex(on: ScenarioDefinitionModel.schema, columns: ["user_id"])
        try await database.createIndex(on: ScenarioSnapshotModel.schema, columns: ["user_id", "created_at"])
        try await database.createIndex(on: ScenarioRunModel.schema, columns: ["user_id", "created_at"])
        try await database.createIndex(on: ScenarioRunModel.schema, columns: ["state", "lease_expires_at"])
        try await database.createIndex(on: ScenarioRunModel.schema, columns: ["deduplication_hash"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ScenarioRunModel.schema).delete()
        try await database.schema(ScenarioSnapshotModel.schema).delete()
        try await database.schema(ScenarioDefinitionModel.schema).delete()
        try await database.schema(FinancialGoalModel.schema).delete()
    }
}
