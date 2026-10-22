import Fluent
import Foundation
import StockPlanShared
import Vapor

struct DigestPriceBar: Sendable, Equatable {
    /// `yyyy-MM-dd`.
    let date: String
    let close: Double
}

/// Everything the digest reads from outside the database. Injected so tests
/// never reach a market-data, earnings or macro provider.
protocol DigestDataSources: Sendable {
    func dailyCloses(symbol: String, from: String, to: String, on req: Request) async throws -> [DigestPriceBar]
    func earnings(from: String, to: String, on req: Request) async throws -> [EarningsItemResponse]
    func personalInflation(userId: UUID, country: MacroCountry, on req: Request) async throws -> PersonalInflationResponse
}

struct LiveDigestDataSources: DigestDataSources {
    func dailyCloses(symbol: String, from: String, to: String, on req: Request) async throws -> [DigestPriceBar] {
        try await req.application.marketDataService.history(symbol: symbol, from: from, to: to, on: req)
            .bars
            .map { DigestPriceBar(date: String($0.date.prefix(10)), close: $0.close) }
    }

    func earnings(from: String, to: String, on req: Request) async throws -> [EarningsItemResponse] {
        try await req.application.earningsService.getCalendar(query: .init(from: from, to: to), on: req)
    }

    func personalInflation(userId: UUID, country: MacroCountry, on req: Request) async throws -> PersonalInflationResponse {
        try await req.application.macroService.personalInflation(userID: userId, country: country, periodMonths: 12, on: req)
    }
}

/// One held line: a symbol in one portfolio currency, shares summed across lists.
struct DigestPosition: Hashable, Sendable {
    let symbol: String
    let currency: String
    let shares: Double
}

/// Reads one user's week. Every number in a digest comes from here; the model
/// (slice 2) only ever describes them.
///
/// Each section fails on its own: a provider outage drops that section and is
/// logged, it never blocks the email. The holdings section is computed from
/// closing prices on current positions, not from portfolio snapshots, so money
/// the user added during the week never shows up as a gain.
struct DigestFactsCollector: Sendable {
    let sources: any DigestDataSources

    /// Trading days are looked up this far before the week so a Monday holiday
    /// still finds the prior close.
    static let lookbackDays = 10
    static let moverCount = 3
    static let budgetLineCount = 2

    func collect(
        userId: UUID,
        period: DigestSchedule.Period,
        preference: DigestPreference?,
        previous: DigestPayload?,
        on req: Request
    ) async throws -> DigestPayload {
        var payload = DigestPayload(periodStart: period.start, periodEnd: period.end)
        let positions = try await positions(userId: userId, on: req.db)

        let closes = await closesBySymbol(Set(positions.map(\.symbol)), period: period, on: req)
        let holdings = Self.holdings(positions: positions, closes: closes, period: period)
        payload.holdings = holdings.moves
        payload.movers = holdings.movers
        payload.pricedPositions = holdings.priced
        payload.totalPositions = positions.count

        do {
            payload.budget = try await budget(userId: userId, period: period, on: req)
        } catch {
            req.logger.warning("digest.section_failed section=budget user=\(userId) error=\(String(describing: error))")
        }

        if let raw = preference?.country, let country = MacroCountry(query: raw) {
            do {
                let response = try await sources.personalInflation(userId: userId, country: country, on: req)
                payload.inflationAsOfSeen = response.asOf
                payload.inflation = Self.inflation(response, previouslySeen: previous?.inflationAsOfSeen)
            } catch {
                req.logger.warning("digest.section_failed section=inflation user=\(userId) error=\(String(describing: error))")
            }
        }

        if !positions.isEmpty, let from = DigestSchedule.shift(period.end, byDays: 1),
           let to = DigestSchedule.shift(period.end, byDays: 7)
        {
            do {
                let calendar = try await sources.earnings(from: from, to: to, on: req)
                payload.earnings = Self.earnings(calendar, held: Set(positions.map(\.symbol)))
            } catch {
                req.logger.warning("digest.section_failed section=earnings user=\(userId) error=\(String(describing: error))")
            }
        }
        return payload
    }

    /// Whether the user has anything a digest could describe.
    static func isEligible(userId: UUID, on db: any Database) async throws -> Bool {
        let holds = try await Stock.query(on: db).filter(\.$userId == userId).filter(\.$shares > 0).count() > 0
        if holds { return true }
        return try await BankConnection.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$status == BankConnectionStatus.active.rawValue)
            .count() > 0
    }

    // MARK: - Holdings

    /// Current positions grouped by (symbol, portfolio currency). Pilot-managed
    /// lists are excluded: their value moves with the pilot, not the user.
    func positions(userId: UUID, on db: any Database) async throws -> [DigestPosition] {
        let pilotLists = try await PilotFollow.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.portfolioListId)
        let query = Stock.query(on: db)
            .join(PortfolioList.self, on: \Stock.$portfolioListId == \PortfolioList.$id)
            .filter(\.$userId == userId)
            .filter(\.$shares > 0)
        if !pilotLists.isEmpty {
            query.filter(\.$portfolioListId !~ pilotLists)
        }
        let rows = try await query.all()
        var shares: [DigestPositionKey: Double] = [:]
        for row in rows {
            let currency = try row.joined(PortfolioList.self).baseCurrency.uppercased()
            shares[DigestPositionKey(symbol: row.symbol.uppercased(), currency: currency), default: 0] += row.shares
        }
        return shares
            .map { DigestPosition(symbol: $0.key.symbol, currency: $0.key.currency, shares: $0.value) }
            .sorted { ($0.symbol, $0.currency) < ($1.symbol, $1.currency) }
    }

    private func closesBySymbol(
        _ symbols: Set<String>,
        period: DigestSchedule.Period,
        on req: Request
    ) async -> [String: [DigestPriceBar]] {
        guard let from = DigestSchedule.shift(period.start, byDays: -Self.lookbackDays) else { return [:] }
        var result: [String: [DigestPriceBar]] = [:]
        for symbol in symbols.sorted() {
            do {
                result[symbol] = try await sources.dailyCloses(symbol: symbol, from: from, to: period.end, on: req)
            } catch {
                req.logger.info("digest.price_missing symbol=\(symbol) error=\(String(describing: error))")
            }
        }
        return result
    }

    struct HoldingsResult: Equatable {
        let moves: [DigestCurrencyMove]
        let movers: [DigestMover]
        let priced: Int
    }

    /// The week's move per currency and the biggest movers. A position counts
    /// only with a close before the week began and a close within it; the rest
    /// are reported as unpriced rather than guessed.
    static func holdings(
        positions: [DigestPosition],
        closes: [String: [DigestPriceBar]],
        period: DigestSchedule.Period
    ) -> HoldingsResult {
        var movers: [DigestMover] = []
        for position in positions {
            let bars = (closes[position.symbol] ?? []).sorted { $0.date < $1.date }
            guard let start = bars.last(where: { $0.date < period.start }),
                  let end = bars.last(where: { $0.date <= period.end }),
                  start.close > 0
            else { continue }
            let contribution = position.shares * (end.close - start.close)
            movers.append(DigestMover(
                symbol: position.symbol,
                currency: position.currency,
                shares: position.shares,
                startPrice: start.close,
                endPrice: end.close,
                contribution: money(contribution),
                changePercent: percent((end.close - start.close) / start.close * 100)
            ))
        }

        var totals: [String: (start: Double, end: Double)] = [:]
        for mover in movers {
            let running = totals[mover.currency] ?? (0, 0)
            totals[mover.currency] = (running.start + mover.shares * mover.startPrice, running.end + mover.shares * mover.endPrice)
        }
        let moves = totals
            .map { currency, value in
                DigestCurrencyMove(
                    currency: currency,
                    startValue: money(value.start),
                    endValue: money(value.end),
                    change: money(value.end - value.start),
                    changePercent: value.start > 0 ? percent((value.end - value.start) / value.start * 100) : nil
                )
            }
            // Largest book first: that is the headline.
            .sorted { ($0.startValue, $1.currency) > ($1.startValue, $0.currency) }

        let top = movers
            .filter { $0.contribution != 0 }
            .sorted { (abs($0.contribution), $1.symbol) > (abs($1.contribution), $0.symbol) }
            .prefix(moverCount)
        return HoldingsResult(moves: moves, movers: Array(top), priced: movers.count)
    }

    // MARK: - Budget

    /// The two budgeted categories furthest from target this month, either way.
    private func budget(userId: UUID, period: DigestSchedule.Period, on req: Request) async throws -> DigestBudget? {
        guard let monthStart = DigestSchedule.parseDay(String(period.end.prefix(7)) + "-01") else { return nil }
        let widenedStart = monthStart.addingTimeInterval(-86400)
        let widenedEnd = monthStart.addingTimeInterval(86400)
        let snapshots = try await BudgetSnapshot.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$monthStart >= widenedStart)
            .filter(\.$monthStart < widenedEnd)
            .all()
        guard let snapshot = snapshots.min(by: {
            abs($0.monthStart.timeIntervalSince(monthStart)) < abs($1.monthStart.timeIntervalSince(monthStart))
        }), let snapshotId = snapshot.id else { return nil }
        let dashboard = try await BudgetingEngineService(req: req).dashboard(userId: userId, snapshotId: snapshotId)
        return Self.budget(dashboard)
    }

    static func budget(_ dashboard: BudgetDriftDashboard) -> DigestBudget? {
        let lines = dashboard.categories
            .filter { $0.targetAmount > 0 && $0.driftAmount != 0 }
            .sorted { (abs($0.driftAmount), $1.title) > (abs($1.driftAmount), $0.title) }
            .prefix(budgetLineCount)
            .map {
                DigestBudgetLine(
                    title: $0.title,
                    target: money($0.targetAmount),
                    actual: money($0.actualAmount),
                    drift: money($0.driftAmount),
                    driftPercent: $0.driftPercent.map(percent)
                )
            }
        guard !lines.isEmpty else { return nil }
        return DigestBudget(monthStart: dashboard.monthStart, currency: dashboard.currencyCode, lines: Array(lines))
    }

    // MARK: - Inflation and earnings

    /// Shown once per new reading: nil when this `asOf` was already seen.
    static func inflation(_ response: PersonalInflationResponse, previouslySeen: String?) -> DigestInflation? {
        guard let personal = response.personalRate, response.asOf != previouslySeen else { return nil }
        return DigestInflation(
            country: response.country,
            asOf: response.asOf,
            personalRate: percent(personal),
            officialRate: percent(response.officialRate)
        )
    }

    static func earnings(_ calendar: [EarningsItemResponse], held: Set<String>) -> [DigestEarning] {
        var seen = Set<String>()
        return calendar
            .compactMap { item -> DigestEarning? in
                guard let symbol = item.symbol?.uppercased(), held.contains(symbol), let date = item.date else { return nil }
                return DigestEarning(symbol: symbol, date: String(date.prefix(10)), hour: item.hour)
            }
            .sorted { ($0.date, $0.symbol) < ($1.date, $1.symbol) }
            .filter { seen.insert($0.symbol).inserted }
    }

    // MARK: - Rounding

    /// Cents, so float noise never reaches an email.
    static func money(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func percent(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

private struct DigestPositionKey: Hashable {
    let symbol: String
    let currency: String
}
