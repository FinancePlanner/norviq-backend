import Fluent
import Foundation

/// Where an unlock came from. Stored as text.
enum AchievementSource: String, Codable, Sendable {
    case live
    case sweep
    case backfill
    case legacyBadge = "legacy_badge"
}

/// One unlocked achievement tier. `achievementKey` and `tier` are text, not
/// enums, so the catalog can grow without a migration. Single-tier
/// achievements use the empty tier. A user holds each (key, tier) once.
final class UserAchievement: Model, @unchecked Sendable {
    static let schema = "user_achievements"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "achievement_key") var achievementKey: String
    @Field(key: "tier") var tier: String
    @Field(key: "unlocked_at") var unlockedAt: Date
    @Field(key: "source") var source: String
    @OptionalField(key: "seen_at") var seenAt: Date?
    @OptionalField(key: "notified_at") var notifiedAt: Date?
    /// Position on the profile showcase; unique per user while set.
    @OptionalField(key: "showcase_rank") var showcaseRank: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        userId: UUID,
        achievementKey: String,
        tier: String = "",
        unlockedAt: Date = Date(),
        source: AchievementSource
    ) {
        $user.id = userId
        self.achievementKey = achievementKey
        self.tier = tier
        self.unlockedAt = unlockedAt
        self.source = source.rawValue
    }
}

/// Evaluation bookkeeping, one row per user, created on the user's first
/// evaluation (or failed sweep). `needsBackfill` starts true exactly when the
/// user was created before achievements were activated
/// (`AchievementService.backfillRule`); later users are evaluated live.
final class AchievementEvaluation: Model, @unchecked Sendable {
    static let schema = "achievement_evaluations"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "needs_backfill") var needsBackfill: Bool
    @OptionalField(key: "last_evaluated_at") var lastEvaluatedAt: Date?
    @OptionalField(key: "last_swept_at") var lastSweptAt: Date?

    init() {}

    init(userId: UUID, needsBackfill: Bool = false) {
        self.userId = userId
        self.needsBackfill = needsBackfill
    }
}
