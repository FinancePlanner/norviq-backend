import Fluent
import Foundation

/// One award of XP. The server is the only writer: clients report facts
/// (a check-in, a budget streak) and the server decides the points.
/// `dedupeKey` is unique per user, so retries and races award once.
final class GamificationXPEvent: Model, @unchecked Sendable {
    static let schema = "gamification_xp_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "type") var type: String
    @Field(key: "points") var points: Int
    @Field(key: "dedupe_key") var dedupeKey: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userId: UUID, type: XPEventTypeDTO, points: Int, dedupeKey: String) {
        self.userId = userId
        self.type = type.rawValue
        self.points = points
        self.dedupeKey = dedupeKey
    }
}

/// One daily check-in, keyed by the user's local calendar day at the time.
final class GamificationCheckIn: Model, @unchecked Sendable {
    static let schema = "gamification_check_ins"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    /// `YYYY-MM-DD` in the time zone the app sent (`X-Timezone`).
    @Field(key: "local_date") var localDate: String
    @Field(key: "time_zone") var timeZone: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userId: UUID, localDate: String, timeZone: String) {
        self.userId = userId
        self.localDate = localDate
        self.timeZone = timeZone
    }
}

/// The budget streak (consecutive months under plan), as last verified.
/// `bestMonths` is the highest level ever reached; XP is paid per new level.
final class GamificationBudgetStreak: Model, @unchecked Sendable {
    static let schema = "gamification_budget_streaks"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "months") var months: Int
    @Field(key: "best_months") var bestMonths: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, months: Int) {
        self.userId = userId
        self.months = months
        bestMonths = months
    }
}
