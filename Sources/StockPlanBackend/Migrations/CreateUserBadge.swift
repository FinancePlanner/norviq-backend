import Fluent
import StockPlanShared

struct CreateUserBadge: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let badgeTypeEnum = try await database.enum("badge_type")
            .case(BadgeType.firstPurchase.rawValue)
            .case(BadgeType.newsReader.rawValue)
            .case(BadgeType.investor.rawValue)
            .case(BadgeType.saver.rawValue)
            .case(BadgeType.frugalFun.rawValue)
            .case(BadgeType.spendingDetox.rawValue)
            .case(BadgeType.growthMindset.rawValue)
            .create()

        let badgeTierEnum = try await database.enum("badge_tier")
            .case(BadgeTier.bronze.rawValue)
            .case(BadgeTier.silver.rawValue)
            .case(BadgeTier.gold.rawValue)
            .create()

        try await database.schema("user_badges")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("badge_type", badgeTypeEnum, .required)
            .field("tier", badgeTierEnum, .required)
            .field("earned_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "badge_type", "tier")
            .create()

        try await database.createIndex(on: "user_badges", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_badges").delete()
        try await database.enum("badge_tier").delete()
        try await database.enum("badge_type").delete()
    }
}
