import Fluent
import Vapor
import Foundation
import StockPlanShared

final class UserBadge: Model, Content, @unchecked Sendable {
    static let schema = "user_badges"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Enum(key: "badge_type")
    var badgeType: BadgeType

    @Enum(key: "tier")
    var tier: BadgeTier

    @Field(key: "earned_at")
    var earnedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        badgeType: BadgeType,
        tier: BadgeTier,
        earnedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.badgeType = badgeType
        self.tier = tier
        self.earnedAt = earnedAt
    }
}
