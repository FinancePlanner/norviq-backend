import Fluent

struct AddCouponGrantType: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Coupon.schema)
            .field("grant_type", .string, .required, .custom("DEFAULT 'trial'"))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Coupon.schema)
            .deleteField("grant_type")
            .update()
    }
}
