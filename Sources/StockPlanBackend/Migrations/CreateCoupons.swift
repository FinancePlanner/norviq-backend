import Fluent

struct CreateCoupons: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("coupons")
            .id()
            .field("code", .string, .required)
            .field("trial_days", .int, .required)
            .field("discount_percentage", .int)
            .field("discount_amount", .int)
            .field("currency", .string)
            .field("max_uses", .int)
            .field("current_uses", .int, .required, .custom("DEFAULT 0"))
            .field("expires_at", .datetime)
            .field("is_active", .bool, .required, .custom("DEFAULT TRUE"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("coupons").delete()
    }
}
