import Fluent

struct CreateCouponRedemptions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(CouponRedemption.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("coupon_id", .uuid, .required, .references(Coupon.schema, "id", onDelete: .cascade))
            .field("code", .string, .required)
            .field("trial_days_granted", .int, .required)
            .field("discount_percentage", .int)
            .field("discount_amount", .int)
            .field("currency", .string)
            .field("redeemed_at", .datetime)
            .unique(on: "user_id", "coupon_id")
            .create()

        try await database.createIndex(on: CouponRedemption.schema, columns: ["user_id"])
        try await database.createIndex(on: CouponRedemption.schema, columns: ["coupon_id"])
        try await database.createIndex(on: CouponRedemption.schema, columns: ["code"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(CouponRedemption.schema).delete()
    }
}
