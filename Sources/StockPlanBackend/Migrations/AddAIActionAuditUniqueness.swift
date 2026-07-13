import Fluent

struct AddAIActionAuditUniqueness: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AIActionAudit.schema).unique(on: "pending_action_id").update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AIActionAudit.schema).deleteUnique(on: "pending_action_id").update()
    }
}
