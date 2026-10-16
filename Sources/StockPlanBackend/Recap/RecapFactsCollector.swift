import Fluent
import Foundation
import StockPlanShared

/// Longest run of consecutive calendar days in a list of `yyyy-MM-dd` strings.
enum RecapStreaks {
    static func longest(localDates: [String]) -> Int {
        let days = Set(localDates.compactMap(dayNumber)).sorted()
        var best = 0
        var run = 0
        var previous: Int?
        for day in days {
            run = previous.map { day == $0 + 1 } == true ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// Days since 1970-01-01 for a `yyyy-MM-dd` string (proleptic Gregorian), nil if malformed.
    static func dayNumber(_ localDate: String) -> Int? {
        let parts = localDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// Reads one user's activity for one period. The only recap code that touches
/// activity tables: one query per source, joins instead of per-row lookups.
///
/// Two kinds of bounds:
/// - `timestamptz` columns (`created_at`, `earned_at`, `occurred_at`,
///   `alert_triggered_at`) use the period cut in the user's zone.
/// - `date` columns (`trade_date`, `pay_date`, `captured_on`, `occurred_on`,
///   `month_start`) are calendar days with no zone, stored and read back as
///   UTC midnight, so they use the period's calendar days.
///
/// `net_worth_snapshots` is never read: it is global, with no `user_id`.
struct RecapFactsCollector: Sendable {
    private struct Window {
        let instants: (start: Date, end: Date)
        let days: (start: Date, end: Date)
        let localDates: (first: String, last: String)
        let firstHalfLast: String
    }

    func collect(userId: UUID, period: RecapPeriod, timeZone: TimeZone, on db: any Database) async throws -> RecapFacts {
        let localDates = period.localDateRange()
        let window = Window(
            instants: period.bounds(in: timeZone),
            days: period.bounds(in: RecapTimeZoneResolver.utc),
            localDates: localDates,
            firstHalfLast: period.month.map { String(format: "%04d-%02d-15", period.year, $0) }
                ?? String(format: "%04d-06-30", period.year)
        )
        var facts = RecapFacts()
        try await collectCheckIns(userId, window, db, into: &facts)
        try await collectTrades(userId, window, db, into: &facts)
        try await collectResearch(userId, window, db, into: &facts)
        try await collectGrowth(userId, window, db, into: &facts)
        try await collectDividends(userId, window, db, into: &facts)
        try await collectGoals(userId, window, db, into: &facts)
        try await collectGamification(userId, window, db, into: &facts)
        try await collectSocial(userId, window, db, into: &facts)
        return facts
    }

    // MARK: - Sources

    private func collectCheckIns(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let all = try await GamificationCheckIn.query(on: db)
            .filter(\.$userId == userId)
            .field(\.$localDate)
            .all()
            .map(\.localDate)
        let inPeriod = Set(all.filter { $0 >= w.localDates.first && $0 <= w.localDates.last })
        facts.activeDays = inPeriod.count
        facts.activeDaysFirstHalf = inPeriod.count { $0 <= w.firstHalfLast }
        facts.activeDaysSecondHalf = inPeriod.count - facts.activeDaysFirstHalf
        facts.longestStreakDays = RecapStreaks.longest(localDates: Array(inPeriod))
        facts.bestStreakEverDays = RecapStreaks.longest(localDates: all)
    }

    private func collectTrades(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let trades = try await Transaction.query(on: db)
            .join(Account.self, on: \Transaction.$accountId == \Account.$id)
            .join(Instrument.self, on: \Transaction.$instrumentId == \Instrument.$id)
            .filter(Account.self, \.$userId == userId)
            .filter(\.$tradeDate >= w.days.start)
            .filter(\.$tradeDate < w.days.end)
            .filter(\.$type ~~ ["BUY", "SELL"])
            .all()
        for trade in trades {
            let symbol = try trade.joined(Instrument.self).symbol.uppercased()
            facts.tradeCount += 1
            if trade.type == "BUY" {
                facts.buyCount += 1
            } else {
                facts.sellCount += 1
            }
            facts.tradesBySymbol[symbol, default: 0] += 1
        }
    }

    private func collectResearch(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let (start, end) = w.instants
        func touch(_ symbol: String) {
            let key = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty else { return }
            facts.researchTouchesBySymbol[key, default: 0] += 1
        }

        let watchlist = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .field(\.$symbol)
            .all()
        facts.watchlistAdded = watchlist.count
        watchlist.forEach { touch($0.symbol) }

        let notes = try await ResearchNote.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .field(\.$symbol)
            .all()
        facts.notesWritten = notes.count
        notes.forEach { touch($0.symbol) }

        // One query for both "set in period" and "hit in period".
        let targets = try await Target.query(on: db)
            .filter(\.$userId == userId)
            .group(.or) { either in
                either.group(.and) { $0.filter(\.$createdAt >= start).filter(\.$createdAt < end) }
                either.group(.and) { $0.filter(\.$alertTriggeredAt >= start).filter(\.$alertTriggeredAt < end) }
            }
            .field(\.$symbol).field(\.$createdAt).field(\.$alertTriggeredAt)
            .all()
        func inPeriod(_ date: Date?) -> Bool {
            date.map { $0 >= start && $0 < end } ?? false
        }
        for target in targets {
            if inPeriod(target.createdAt) {
                facts.targetsSet += 1
                touch(target.symbol)
            }
            if inPeriod(target.alertTriggeredAt) {
                facts.targetsHit += 1
            }
        }

        // Only the symbol: the memo body is encrypted and large.
        let memos = try await PositionMemo.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .field(\.$primarySymbol)
            .all()
        memos.forEach { touch($0.primarySymbol) }

        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .field(\.$symbol)
            .all()
        stocks.forEach { touch($0.symbol) }
    }

    /// Per currency: summed market value on the earliest and the latest
    /// snapshot day in the period. Emitted only when those days differ.
    private func collectGrowth(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let snapshots = try await PortfolioValueSnapshot.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$capturedOn >= w.days.start)
            .filter(\.$capturedOn < w.days.end)
            .all()
        facts.growth = Dictionary(grouping: snapshots, by: \.currency)
            .sorted { $0.key < $1.key }
            .compactMap { currency, rows in
                guard let first = rows.map(\.capturedOn).min(), let last = rows.map(\.capturedOn).max(),
                      first != last
                else { return nil }
                func total(on day: Date) -> Double {
                    Self.money(rows.filter { $0.capturedOn == day }.reduce(0) { $0 + $1.marketValue })
                }
                return RecapGrowth(currency: currency, startValue: total(on: first), endValue: total(on: last))
            }
    }

    private func collectDividends(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let dividends = try await Dividend.query(on: db)
            .join(Account.self, on: \Dividend.$accountId == \Account.$id)
            .filter(Account.self, \.$userId == userId)
            .filter(\.$payDate >= w.days.start)
            .filter(\.$payDate < w.days.end)
            .all()
        facts.dividendsReceived = Self.byCurrency(dividends.map { ($0.currency, $0.amount) })
        facts.dividendPayments = dividends.count
        facts.dividendPayers = Set(dividends.map(\.instrumentId)).count
    }

    /// The currency is the parent goal's `base_currency`.
    private func collectGoals(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let contributions = try await GoalContributionModel.query(on: db)
            .join(FinancialGoalModel.self, on: \GoalContributionModel.$goal.$id == \FinancialGoalModel.$id)
            .filter(\.$userId == userId)
            .filter(\.$occurredAt >= w.instants.start)
            .filter(\.$occurredAt < w.instants.end)
            .all()
        let pairs = try contributions.map { try ($0.joined(FinancialGoalModel.self).baseCurrency, $0.amount) }
        facts.goalContributions = Self.byCurrency(pairs)
        facts.goalContributionCount = contributions.count
    }

    private func collectGamification(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let (start, end) = w.instants
        let badges = try await UserBadge.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$earnedAt, .ascending)
            .all()
        facts.totalBadgesEver = badges.count
        facts.badgesEarned = badges
            .filter { $0.earnedAt >= start && $0.earnedAt < end }
            .map { RecapBadge(type: $0.badgeType.rawValue, tier: $0.tier.rawValue) }

        // Summed in Swift: SUM over a bigint column comes back as NUMERIC.
        facts.xpEarned = try await GamificationXPEvent.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .field(\.$points)
            .all()
            .reduce(0) { $0 + $1.points }
    }

    private func collectSocial(_ userId: UUID, _ w: Window, _ db: any Database, into facts: inout RecapFacts) async throws {
        let (start, end) = w.instants
        facts.pilotFollows = try await PilotFollow.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .count()
        // Soft-deleted posts and comments are excluded by Fluent's default scope.
        facts.boardPosts = try await BoardPost.query(on: db)
            .filter(\.$authorId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .count()
        facts.boardComments = try await BoardCommentRecord.query(on: db)
            .filter(\.$authorId == userId)
            .filter(\.$createdAt >= start).filter(\.$createdAt < end)
            .count()
        // `month_start` is the UTC month start, a `date`.
        facts.aiRequests = try await AIAssistantUsage.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$monthStart >= w.days.start)
            .filter(\.$monthStart < w.days.end)
            .field(\.$requestCount)
            .all()
            .reduce(0) { $0 + $1.requestCount }
        facts.expensesRecorded = try await Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= w.days.start)
            .filter(\.$occurredOn < w.days.end)
            .count()
    }

    // MARK: - Money

    /// Sums per currency, never across currencies. Sorted by currency code.
    private static func byCurrency(_ amounts: [(currency: String, amount: Double)]) -> [RecapMoney] {
        Dictionary(grouping: amounts, by: \.currency)
            .map { RecapMoney(amount: money($0.value.reduce(0) { $0 + $1.amount }), currency: $0.key) }
            .sorted { $0.currency < $1.currency }
    }

    /// Rounds to cents so float noise (0.1 + 0.2) never reaches a slide.
    private static func money(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
