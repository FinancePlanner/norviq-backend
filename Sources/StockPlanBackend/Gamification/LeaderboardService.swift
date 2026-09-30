import Fluent
import Foundation
import Vapor

/// Friends-only leaderboards. Ranked: the caller and their friends, minus
/// blocks either way, suspended users and anyone who opted out. Values are
/// percentages or counts; no amount of money is ever read into a response.
enum LeaderboardService {
    struct Ranked {
        let user: SocialUserSummaryDTO
        let value: Double
    }

    static func leaderboard(
        metric: LeaderboardMetricDTO,
        period: LeaderboardPeriodDTO,
        viewer: UUID,
        now: Date,
        timeZone: TimeZone,
        on db: any Database
    ) async throws -> LeaderboardResponseDTO {
        let interval = GamificationCalendar.period(period, containing: now, in: timeZone)
        let participants = try await Self.participants(for: viewer, metric: metric, on: db)

        let values: [UUID: Double]
        switch metric {
        case .xp:
            let xp = try await XPService.xpByUser(participants, in: interval, on: db)
            values = Dictionary(uniqueKeysWithValues: participants.map { ($0, Double(xp[$0] ?? 0)) })
        case .checkInStreak:
            let days = try await XPService.checkInDays(for: participants, on: db)
            let today = GamificationCalendar.dayNumber(GamificationCalendar.localDate(now, in: timeZone)) ?? 0
            values = Dictionary(uniqueKeysWithValues: participants.map {
                ($0, Double(XPService.currentStreak(days: days[$0] ?? [], today: today)))
            })
        case .budgetStreak:
            let months = try await XPService.budgetMonths(for: participants, on: db)
            values = Dictionary(uniqueKeysWithValues: participants.map { ($0, Double(months[$0] ?? 0)) })
        case .returnPercent:
            // Only users with measured history appear; nobody gets a made-up 0%.
            values = try await LeaderboardReturns.percentByUser(participants, interval: interval, on: db)
        }

        let summaries = try await SocialService.summaries(for: Array(values.keys), viewer: viewer, on: db)
        var ranked: [Ranked] = []
        for (userId, value) in values {
            guard let user = summaries[userId] else { continue }
            ranked.append(Ranked(user: user, value: value))
        }
        ranked.sort { lhs, rhs in
            lhs.value == rhs.value ? lhs.user.username < rhs.user.username : lhs.value > rhs.value
        }

        var entries: [LeaderboardEntryDTO] = []
        for (index, item) in ranked.enumerated() {
            // Ties share a rank (1, 1, 3).
            var rank = index + 1
            if index > 0, ranked[index - 1].value == item.value, let previous = entries.last {
                rank = previous.rank
            }
            entries.append(LeaderboardEntryDTO(rank: rank, user: item.user, value: item.value, isMe: item.user.id == viewer))
        }

        return LeaderboardResponseDTO(
            metric: metric,
            period: period,
            entries: entries,
            periodStart: interval.start,
            periodEnd: interval.end
        )
    }

    /// The caller plus friends, visible to each other and opted in for this
    /// metric. Return % also needs `showReturnPercent`; XP needs `showXP`;
    /// streaks need `showStreaks`.
    static func participants(for viewer: UUID, metric: LeaderboardMetricDTO, on db: any Database) async throws -> [UUID] {
        let hidden = try await SocialService.blockedEitherWay(for: viewer, on: db)
        var candidates = try await SocialService.friendIds(of: viewer, on: db).subtracting(hidden)
        candidates.insert(viewer)
        let ids = Array(candidates)
        let settings = try await SocialService.settings(for: ids, on: db)
        return ids.filter { id in
            guard let setting = settings[id], setting.leaderboardOptIn else { return false }
            switch metric {
            case .returnPercent: return setting.showReturnPercent
            case .xp: return setting.showXP
            case .checkInStreak, .budgetStreak: return setting.showStreaks
            }
        }
    }
}

/// Period return for leaderboards, from the daily portfolio snapshots the
/// performance chart already uses (`portfolio_value_snapshots`).
///
/// Time-weighted: the period is split at every recorded day and the daily
/// returns are chained, treating the day's change in cost basis as money moved
/// in or out, so buying more doesn't count as a gain. Holdings only; cash is
/// left out because deposits land there.
///
/// Limits: snapshots have no sell log, so a sale shows up as its realized
/// gain leaving (a day's return is understated by gain ÷ value). Users with
/// fewer than two usable days in the window are left off the board.
enum LeaderboardReturns {
    struct Point: Equatable {
        let day: Date
        let marketValue: Double
        let costBasis: Double
    }

    static func percentByUser(_ userIds: [UUID], interval: DateInterval, on db: any Database) async throws -> [UUID: Double] {
        guard !userIds.isEmpty else { return [:] }
        let lists = try await PortfolioList.query(on: db)
            .filter(\.$userId ~~ userIds)
            .filter(\.$mode == PortfolioMode.actual.rawValue)
            .filter(\.$archivedAt == nil)
            .all()
        var listIdsByUser: [UUID: [UUID]] = [:]
        for list in lists {
            guard let id = list.id else { continue }
            listIdsByUser[list.userId, default: []].append(id)
        }
        let allListIds = listIdsByUser.values.reduce(into: [UUID]()) { $0.append(contentsOf: $1) }
        guard !allListIds.isEmpty else { return [:] }

        // A week of slack finds the last recorded day on or before the start.
        let from = PortfolioSnapshotValuator.addDays(PortfolioSnapshotValuator.startOfDay(interval.start), days: -7)
        let snapshots = try await PortfolioValueSnapshot.query(on: db)
            .filter(\.$userId ~~ Array(listIdsByUser.keys))
            .filter(\.$portfolioListId ~~ allListIds)
            .filter(\.$capturedOn >= from)
            .filter(\.$capturedOn < interval.end)
            .all()
        let byUser = Dictionary(grouping: snapshots, by: \.userId)

        var result: [UUID: Double] = [:]
        for (userId, rows) in byUser {
            let points = Self.points(from: rows, listIds: listIdsByUser[userId] ?? [])
            if let percent = timeWeightedPercent(points, periodStart: interval.start) {
                result[userId] = percent
            }
        }
        return result
    }

    /// Holdings value and cost per day, keeping only days on which every list
    /// that had started recording has a row (the performance chart's rule).
    static func points(from snapshots: [PortfolioValueSnapshot], listIds: [UUID]) -> [Point] {
        let complete = Set(PortfolioPerformanceBuilder.days(from: snapshots, listIds: listIds).map(\.date))
        let wanted = Set(listIds)
        var byDay: [Date: (marketValue: Double, costBasis: Double)] = [:]
        for snapshot in snapshots where wanted.contains(snapshot.portfolioListId) {
            let day = PortfolioSnapshotValuator.startOfDay(snapshot.capturedOn)
            guard complete.contains(day) else { continue }
            let current = byDay[day] ?? (0, 0)
            byDay[day] = (current.marketValue + snapshot.marketValue, current.costBasis + snapshot.costBasis)
        }
        return byDay.keys.sorted().compactMap { day in
            byDay[day].map { Point(day: day, marketValue: $0.marketValue, costBasis: $0.costBasis) }
        }
    }

    /// Chained daily returns from the last day on or before `periodStart` (or
    /// the first day after it) to the latest day. Nil when nothing measurable.
    static func timeWeightedPercent(_ points: [Point], periodStart: Date) -> Double? {
        guard points.count >= 2 else { return nil }
        let start = PortfolioSnapshotValuator.startOfDay(periodStart)
        let baseIndex = points.lastIndex { $0.day <= start } ?? 0
        guard baseIndex < points.count - 1 else { return nil }

        var growth = 1.0
        var measured = false
        for index in (baseIndex + 1) ..< points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard previous.marketValue > 0 else { continue }
            let flow = current.costBasis - previous.costBasis
            let ratio = (current.marketValue - flow) / previous.marketValue
            guard ratio.isFinite, ratio > 0 else { continue }
            growth *= ratio
            measured = true
        }
        guard measured else { return nil }
        return ((growth - 1) * 10000).rounded() / 100
    }
}
