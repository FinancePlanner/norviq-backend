import Fluent

struct AddSubscriptionPlanChangeFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Subscription.schema)
            .field("store", .string)
            .field("pending_product_id", .string)
            .field("pending_plan", .string)
            .field("pending_plan_effective_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Subscription.schema)
            .deleteField("pending_plan_effective_at")
            .deleteField("pending_plan")
            .deleteField("pending_product_id")
            .deleteField("store")
            .update()
    }
}
