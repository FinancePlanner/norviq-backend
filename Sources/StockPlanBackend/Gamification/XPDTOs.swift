import Foundation
import Vapor

// Wire types for /v1/gamification and /v1/social/leaderboards. They mirror
// financeplan/API/Gamification/GamificationDTOs.swift in the iOS app field for
// field. No type here carries money: only counts, levels and percentages.

enum XPEventTypeDTO: String, Codable, Sendable, CaseIterable {
    case checkIn = "check_in"
    case streakMilestone = "streak_milestone"
    case badgeEarned = "badge_earned"
    case expenseLogged = "expense_logged"
    case budgetStreakMonth = "budget_streak_month"
}

struct XPSummaryDTO: Content, Equatable {
    let total: Int
    let level: Int
    /// Share of the way from `level` to the next one, 0–1.
    let levelProgress: Double
    let weekXP: Int
}

struct XPEventDTO: Content, Equatable {
    let id: UUID
    let type: String
    let points: Int
    let createdAt: Date
}

struct XPHistoryResponseDTO: Content, Equatable {
    let events: [XPEventDTO]
    let nextCursor: String?
}

struct StreakSummaryDTO: Content, Equatable {
    let checkInCurrent: Int
    let checkInLongest: Int
    let budgetMonths: Int
    let lastCheckInDate: String?
}

struct CheckInResponseDTO: Content, Equatable {
    let streak: Int
    let xpAwarded: Int
    let alreadyCheckedIn: Bool
}

struct BudgetStreakReportBody: Content {
    let months: Int
}

enum LeaderboardMetricDTO: String, Codable, Sendable, CaseIterable {
    case returnPercent = "return_percent"
    case xp
    case checkInStreak = "check_in_streak"
    case budgetStreak = "budget_streak"
}

enum LeaderboardPeriodDTO: String, Codable, Sendable, CaseIterable {
    case week
    case month
}

struct LeaderboardEntryDTO: Content, Equatable {
    let rank: Int
    let user: SocialUserSummaryDTO
    /// A percent (4.2 means +4.2%) for `return_percent`, otherwise a count.
    let value: Double
    let isMe: Bool
}

struct LeaderboardResponseDTO: Content, Equatable {
    let metric: LeaderboardMetricDTO
    let period: LeaderboardPeriodDTO
    let entries: [LeaderboardEntryDTO]
    let periodStart: Date
    let periodEnd: Date
}
