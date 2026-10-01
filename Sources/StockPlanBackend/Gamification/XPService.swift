import Fluent
import Foundation
import StockPlanShared
import Vapor

/// How many points each fact is worth. Only the server reads this table.
enum XPRules {
    static let checkIn = 10
    /// Paid at most once per UTC day, so logging many expenses farms nothing.
    static let expenseLogged = 5
    /// Per new budget-streak month level, paid once per level ever reached.
    static let budgetStreakMonth = 25
    /// Bonus on the day a check-in streak reaches these lengths.
    static let streakMilestones: [Int: Int] = [7: 50, 30: 150, 100: 500]
    static let maxBudgetMonths = 120

    static func badge(_ tier: BadgeTier) -> Int {
        switch tier {
        case .bronze: 25
        case .silver: 50
        case .gold: 100
        }
    }
}

/// The level curve. Reaching level L takes `50·L·(L−1)` XP in total: level 2
/// at 100, 3 at 300, 4 at 600, 5 at 1,000. Each level costs 100 more than the
/// one before (L → L+1 costs 100·L).
enum XPLevel {
    static func threshold(for level: Int) -> Int {
        50 * level * (level - 1)
    }

    static func level(for total: Int) -> Int {
        let total = max(0, total)
        var level = max(1, Int((1 + (1 + 0.08 * Double(total)).squareRoot()) / 2))
        while level > 1, threshold(for: level) > total {
            level -= 1
        }
        while threshold(for: level + 1) <= total {
            level += 1
        }
        return level
    }

    static func progress(for total: Int) -> Double {
        let total = max(0, total)
        let level = Self.level(for: total)
        let floor = threshold(for: level)
        let next = threshold(for: level + 1)
        guard next > floor else { return 0 }
        return min(1, max(0, Double(total - floor) / Double(next - floor)))
    }
}

/// Local days and leaderboard periods. Check-ins are keyed by the caller's
/// calendar day in the `X-Timezone` zone (an IANA id; UTC when absent or
/// unknown). Weeks start on Monday.
enum GamificationCalendar {
    static let timezoneHeader = "X-Timezone"
    static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    static func timeZone(from req: Request) -> TimeZone {
        guard let raw = req.headers.first(name: timezoneHeader)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 64,
              let zone = TimeZone(identifier: raw)
        else {
            return utc
        }
        return zone
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// `YYYY-MM-DD` for `date` as seen in `zone`.
    static func localDate(_ date: Date, in zone: TimeZone) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return "\(pad(parts.year ?? 1970, 4))-\(pad(parts.month ?? 1, 2))-\(pad(parts.day ?? 1, 2))"
    }

    /// Days since 1970-01-01 for a `YYYY-MM-DD` string, so streaks are integer steps.
    static func dayNumber(_ localDate: String) -> Int? {
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar(utc).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else {
            return nil
        }
        return Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }

    static func period(_ period: LeaderboardPeriodDTO, containing now: Date, in zone: TimeZone) -> DateInterval {
        let component: Calendar.Component = period == .week ? .weekOfYear : .month
        return calendar(zone).dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

/// XP ledger, check-in streaks and the budget streak. Points are only ever
/// written through `award`, which is idempotent per dedupe key.
enum XPService {
    // MARK: - Awards

    /// Awards `points` once per `dedupeKey`. Returns what was awarded: 0 when
    /// this key was already paid.
    @discardableResult
    static func award(
        _ kind: XPEventTypeDTO,
        points: Int,
        to userId: UUID,
        dedupeKey: String,
        on db: any Database
    ) async throws -> Int {
        guard points > 0 else { return 0 }
        let existing = try await GamificationXPEvent.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$dedupeKey == dedupeKey)
            .first()
        guard existing == nil else { return 0 }
        let saved = try await insertIgnoringDuplicate(
            GamificationXPEvent(userId: userId, type: kind, points: points, dedupeKey: dedupeKey),
            on: db
        )
        // Not saved: a concurrent request paid this key first.
        return saved ? points : 0
    }

    /// Saves `model`. Returns false instead of throwing when a unique
    /// constraint rejects it, which means a concurrent request won the race.
    static func insertIgnoringDuplicate(_ model: some Model, on db: any Database) async throws -> Bool {
        do {
            try await model.save(on: db)
            return true
        } catch {
            guard isConstraintFailure(error) else { throw error }
            return false
        }
    }

    static func isConstraintFailure(_ error: any Error) -> Bool {
        guard let databaseError = error as? any DatabaseError else { return false }
        return databaseError.isConstraintFailure
    }

    /// For hooks in other features. Never fails the request that triggered it,
    /// and writes nothing while leaderboards are switched off.
    static func awardBestEffort(
        _ kind: XPEventTypeDTO,
        points: Int,
        to userId: UUID,
        dedupeKey: String,
        on db: any Database,
        logger: Logger
    ) async {
        guard SocialConfiguration.fromEnvironment().leaderboards else { return }
        do {
            try await award(kind, points: points, to: userId, dedupeKey: dedupeKey, on: db)
        } catch {
            logger.warning("xp.award failed type=\(kind.rawValue) error=\(String(reflecting: type(of: error)))")
        }
    }

    // MARK: - XP

    static func summary(for userId: UUID, now: Date, timeZone: TimeZone, on db: any Database) async throws -> XPSummaryDTO {
        // Summed in Swift: `points` is a bigint and Postgres returns
        // SUM(bigint) as numeric, which Fluent cannot decode into Int.
        let total = try await GamificationXPEvent.query(on: db)
            .filter(\.$userId == userId)
            .all(\.$points)
            .reduce(0, +)
        let week = GamificationCalendar.period(.week, containing: now, in: timeZone)
        let weekXP = try await GamificationXPEvent.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= week.start)
            .all(\.$points)
            .reduce(0, +)
        return XPSummaryDTO(
            total: total,
            level: XPLevel.level(for: total),
            levelProgress: XPLevel.progress(for: total),
            weekXP: weekXP
        )
    }

    /// Newest first. The cursor is an opaque offset.
    static func events(for userId: UUID, cursor: String?, limit: Int, on db: any Database) async throws -> XPHistoryResponseDTO {
        let offset = max(0, cursor.flatMap { Int($0) } ?? 0)
        let pageSize = min(max(limit, 1), 100)
        let rows = try await GamificationXPEvent.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .offset(offset)
            .limit(pageSize + 1)
            .all()
        let events = rows.prefix(pageSize).compactMap { row -> XPEventDTO? in
            guard let id = row.id else { return nil }
            return XPEventDTO(id: id, type: row.type, points: row.points, createdAt: row.createdAt ?? Date())
        }
        return XPHistoryResponseDTO(
            events: events,
            nextCursor: rows.count > pageSize ? String(offset + pageSize) : nil
        )
    }

    /// XP earned by each user inside `interval`. Users without events are absent.
    static func xpByUser(_ userIds: [UUID], in interval: DateInterval, on db: any Database) async throws -> [UUID: Int] {
        guard !userIds.isEmpty else { return [:] }
        let rows = try await GamificationXPEvent.query(on: db)
            .filter(\.$userId ~~ userIds)
            .filter(\.$createdAt >= interval.start)
            .filter(\.$createdAt < interval.end)
            .all()
        var result: [UUID: Int] = [:]
        for row in rows {
            result[row.userId, default: 0] += row.points
        }
        return result
    }

    /// What a social profile shows: the check-in streak when the owner
    /// shares streaks and the XP level when they share XP. People always see
    /// their own. Both nil while leaderboards are switched off.
    static func profileStats(
        of target: UUID,
        viewer: UUID,
        timeZone: TimeZone,
        on db: any Database
    ) async throws -> ProfileStats {
        guard SocialConfiguration.fromEnvironment().leaderboards else { return ProfileStats(streakDays: nil, xpLevel: nil) }
        let settings = try await SocialService.settings(for: [target], on: db)[target] ?? SocialPrivacySettingsDTO.default
        let isSelf = target == viewer
        let now = Date()
        var stats = ProfileStats(streakDays: nil, xpLevel: nil)
        if isSelf || settings.showStreaks {
            let streak = try await currentStreak(for: target, now: now, timeZone: timeZone, on: db)
            stats = ProfileStats(streakDays: streak, xpLevel: stats.xpLevel)
        }
        if isSelf || settings.showXP {
            let xp = try await summary(for: target, now: now, timeZone: GamificationCalendar.utc, on: db)
            stats = ProfileStats(streakDays: stats.streakDays, xpLevel: xp.level)
        }
        return stats
    }

    struct ProfileStats: Sendable {
        let streakDays: Int?
        let xpLevel: Int?
    }

    // MARK: - Check-in streaks

    static func currentStreak(for userId: UUID, now: Date, timeZone: TimeZone, on db: any Database) async throws -> Int {
        let days = try await checkInDays(for: [userId], on: db)[userId] ?? []
        let today = GamificationCalendar.dayNumber(GamificationCalendar.localDate(now, in: timeZone)) ?? 0
        return currentStreak(days: days, today: today)
    }

    /// Checks the user in for their local day. Idempotent: a second call the
    /// same day awards nothing and reports `alreadyCheckedIn`.
    static func checkIn(userId: UUID, now: Date, timeZone: TimeZone, on db: any Database) async throws -> CheckInResponseDTO {
        let localDate = GamificationCalendar.localDate(now, in: timeZone)
        let existing = try await GamificationCheckIn.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$localDate == localDate)
            .first()
        var inserted = false
        if existing == nil {
            let checkIn = GamificationCheckIn(userId: userId, localDate: localDate, timeZone: timeZone.identifier)
            inserted = try await insertIgnoringDuplicate(checkIn, on: db)
        }
        let alreadyCheckedIn = !inserted

        let days = try await checkInDays(for: [userId], on: db)[userId] ?? []
        let today = GamificationCalendar.dayNumber(localDate) ?? 0
        let streak = currentStreak(days: days, today: today)
        guard !alreadyCheckedIn else {
            return CheckInResponseDTO(streak: streak, xpAwarded: 0, alreadyCheckedIn: true)
        }

        var awarded = try await award(.checkIn, points: XPRules.checkIn, to: userId, dedupeKey: "check_in:\(localDate)", on: db)
        if let bonus = XPRules.streakMilestones[streak] {
            awarded += try await award(
                .streakMilestone,
                points: bonus,
                to: userId,
                dedupeKey: "streak_milestone:\(streak):\(localDate)",
                on: db
            )
        }
        return CheckInResponseDTO(streak: streak, xpAwarded: awarded, alreadyCheckedIn: false)
    }

    static func streaks(for userId: UUID, now: Date, timeZone: TimeZone, on db: any Database) async throws -> StreakSummaryDTO {
        let days = try await checkInDays(for: [userId], on: db)[userId] ?? []
        let today = GamificationCalendar.dayNumber(GamificationCalendar.localDate(now, in: timeZone)) ?? 0
        let last = try await GamificationCheckIn.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$localDate, .descending)
            .first()
        let budget = try await GamificationBudgetStreak.query(on: db).filter(\.$userId == userId).first()
        return StreakSummaryDTO(
            checkInCurrent: currentStreak(days: days, today: today),
            checkInLongest: longestStreak(days: days),
            budgetMonths: budget?.months ?? 0,
            lastCheckInDate: last?.localDate
        )
    }

    /// Check-in days per user, as day numbers.
    static func checkInDays(for userIds: [UUID], on db: any Database) async throws -> [UUID: Set<Int>] {
        guard !userIds.isEmpty else { return [:] }
        let rows = try await GamificationCheckIn.query(on: db).filter(\.$userId ~~ userIds).all()
        var result: [UUID: Set<Int>] = [:]
        for row in rows {
            guard let day = GamificationCalendar.dayNumber(row.localDate) else { continue }
            result[row.userId, default: []].insert(day)
        }
        return result
    }

    /// The run of consecutive days ending on the latest check-in, provided that
    /// check-in is no older than yesterday. A streak survives until a whole
    /// local day passes without one. A day ahead of `today` counts too: a
    /// friend east of the viewer may already be on tomorrow.
    static func currentStreak(days: Set<Int>, today: Int) -> Int {
        guard let last = days.filter({ $0 <= today + 1 }).max(), last >= today - 1 else { return 0 }
        var streak = 0
        var day = last
        while days.contains(day) {
            streak += 1
            day -= 1
        }
        return streak
    }

    static func longestStreak(days: Set<Int>) -> Int {
        var longest = 0
        var run = 0
        var previous: Int?
        for day in days.sorted() {
            run = previous == day - 1 ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        return longest
    }

    // MARK: - Budget streak

    /// Stores the budget streak and pays XP for each month level never reached
    /// before. `reported` is what the app says; `verified` is what the server
    /// computes from expense data, and the lower of the two wins.
    @discardableResult
    static func recordBudgetStreak(
        userId: UUID,
        reported: Int,
        verified: Int,
        on db: any Database
    ) async throws -> Int {
        let months = max(0, min(reported, verified, XPRules.maxBudgetMonths))
        let record = try await GamificationBudgetStreak.query(on: db).filter(\.$userId == userId).first()
        let previousBest = record?.bestMonths ?? 0
        if let record {
            record.months = months
            record.bestMonths = max(record.bestMonths, months)
            try await record.save(on: db)
        } else {
            let inserted = try await insertIgnoringDuplicate(GamificationBudgetStreak(userId: userId, months: months), on: db)
            // Not inserted: a concurrent report created the row; its award covers this one.
            guard inserted else { return months }
        }
        if months > previousBest {
            try await award(
                .budgetStreakMonth,
                points: XPRules.budgetStreakMonth * (months - previousBest),
                to: userId,
                dedupeKey: "budget_streak_month:\(months)",
                on: db
            )
        }
        return months
    }

    /// The budget streak as the dashboard computes it: consecutive months,
    /// newest first, with spending at or under a non-zero plan.
    static func verifiedBudgetStreak(userId: UUID, req: Request) async throws -> Int {
        let reports = try await req.expensesService.getMonthlyReports(userId: userId, from: nil, to: nil, on: req.db)
        var streak = 0
        for report in reports.reversed() {
            guard report.actual <= report.planned, report.planned > 0 else { break }
            streak += 1
        }
        return streak
    }

    static func budgetMonths(for userIds: [UUID], on db: any Database) async throws -> [UUID: Int] {
        guard !userIds.isEmpty else { return [:] }
        let rows = try await GamificationBudgetStreak.query(on: db).filter(\.$userId ~~ userIds).all()
        return Dictionary(rows.map { ($0.userId, $0.months) }, uniquingKeysWith: { first, _ in first })
    }
}
