import StockPlanShared
import Vapor

// MARK: - Badges
extension BadgeType: @retroactive Content {}
extension BadgeTier: @retroactive Content {}
extension EarnedTierInfo: @retroactive Content {}
extension BadgeProgressResponse: @retroactive Content {}
extension BadgesListResponse: @retroactive Content {}
