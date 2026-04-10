import Fluent

struct AddTargetAlertFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Target.schema)
            .field("alert_triggered_at", .datetime)
            .field("alert_triggered_price", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Target.schema)
            .deleteField("alert_triggered_at")
            .deleteField("alert_triggered_price")
            .update()
    }
}
