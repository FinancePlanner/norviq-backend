import Fluent
import Vapor

struct AddBudgetAlertThreshold: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BudgetSnapshot.schema)
            .field("last_budget_alert_threshold", .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BudgetSnapshot.schema)
            .deleteField("last_budget_alert_threshold")
            .update()
    }
}
