import Foundation
import Vapor

/// Wire contract of `/v1/achievements`. No money anywhere; performance
/// achievements never carry progress.
struct AchievementTierDTO: Content {
    let tier: String
    let threshold: Int?
    let xp: Int
    let unlockId: UUID?
    let unlockedAt: Date?
    let showcaseRank: Int?
}

struct AchievementProgressDTO: Content {
    let current: Int
    let target: Int
}

struct AchievementDTO: Content {
    let key: String
    let category: String
    let title: String
    let description: String
    let iconKey: String
    /// "earned" (all tiers) | "inProgress" | "locked" | "hidden"
    let state: String
    /// Highest earned tier; "" for an earned single-tier achievement; nil when none.
    let currentTier: String?
    let progress: AchievementProgressDTO?
    let isPerformance: Bool
    let tiers: [AchievementTierDTO]
}

struct AchievementCategoryDTO: Content {
    let key: String
    let title: String
}

struct AchievementSummaryDTO: Content {
    let unlocked: Int
    let total: Int
    let hiddenRemaining: Int
}

struct AchievementsResponseDTO: Content {
    let summary: AchievementSummaryDTO
    let categories: [AchievementCategoryDTO]
    let achievements: [AchievementDTO]
}

struct AchievementUnlockDTO: Content {
    let id: UUID
    let key: String
    let tier: String
    let title: String
    let description: String
    let iconKey: String
    let xp: Int
    let unlockedAt: Date
}

struct AchievementSeenBody: Content {
    let ids: [UUID]
}

struct AchievementShowcaseItem: Content {
    let key: String
    let tier: String
}

struct AchievementShowcaseBody: Content {
    let items: [AchievementShowcaseItem]
}
