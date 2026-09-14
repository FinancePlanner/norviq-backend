import Fluent

struct CreatePlanningScenarios: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PlanningScenarioRecord.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("kind", .string, .required)
            .field("is_default", .bool, .required)
            .field("input_json", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "name")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PlanningScenarioRecord.schema).delete()
    }
}
