import Fluent
import Foundation
import SQLKit
import StockPlanShared
import Vapor

typealias PilotQuoteFetcher = @Sendable (_ symbol: String) async throws -> Double
typealias PilotInstrumentResolver = @Sendable (_ symbol: String) async -> UUID?
typealias PilotWatchlistLimit = @Sendable (_ userId: UUID, _ currentCount: Int, _ db: any Database) async throws -> Void

enum PilotMirrorError: Error, Equatable {
    case quotesUnavailable
}

/// Applies a pilot's book version to one follow.
///
/// Prices are live quotes taken now, when Norviq applies the book. They are
/// never the pilot's historical trade price: the disclosure arrived weeks
/// later, and pretending the follower bought on the original date would
/// overstate what copying the pilot returns.
struct PilotMirrorService: Sendable {
    private let quote: PilotQuoteFetcher
    private let instrument: PilotInstrumentResolver
    private let watchlistLimit: PilotWatchlistLimit
    private let recorder = LedgerTradeRecorder()

    init(quote: @escaping PilotQuoteFetcher, instrument: @escaping PilotInstrumentResolver, watchlistLimit: @escaping PilotWatchlistLimit) {
        self.quote = quote
        self.instrument = instrument
        self.watchlistLimit = watchlistLimit
    }

    func apply(follow: PilotFollow, pilot: Pilot, version: PilotBookVersion, previous: PilotBookVersion?, now: Date, on db: any Database) async throws -> Bool {
        switch follow.target {
        case .portfolio:
            try await applyPortfolio(follow: follow, version: version, now: now, on: db)
        case .watchlist:
            try await applyWatchlist(follow: follow, pilot: pilot, version: version, previous: previous, now: now, on: db)
        }
    }

    // MARK: - Portfolio

    private func applyPortfolio(follow: PilotFollow, version: PilotBookVersion, now: Date, on db: any Database) async throws -> Bool {
        guard let listId = follow.portfolioListId else { return false }
        let followId = try follow.requireID()

        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == follow.userId)
            .filter(\.$portfolioListId == listId)
            .all()
        let holdings = stocks.reduce(into: [String: Double]()) { $0[$1.symbol, default: 0] += $1.shares }
        let account = try await PilotAccountResolver.findOrCreate(userId: follow.userId, portfolioId: listId, on: db)
        let cash = try await CashBalance.query(on: db)
            .filter(\.$accountId == account.requireID())
            .all()
            .reduce(0.0) { $0 + $1.balance }

        // Quotes and instruments resolve before the transaction opens: both may
        // reach the network, and a failure inside db.transaction poisons it.
        var prices: [String: Double] = [:]
        for symbol in Set(version.weights.keys).union(holdings.keys) {
            do {
                let price = try await quote(symbol)
                if price > 0, price.isFinite {
                    prices[symbol] = price
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        // A total quote outage must not consume the book version: throw before
        // claiming so applied_version stays put and the job retries.
        if prices.isEmpty, !version.weights.isEmpty || !holdings.isEmpty {
            throw PilotMirrorError.quotesUnavailable
        }
        let plan = PilotRebalancePlanner.plan(weights: version.weights, holdings: holdings, cash: cash, prices: prices)
        var instruments: [String: UUID] = [:]
        for order in plan.orders {
            if let id = await instrument(order.symbol) {
                instruments[order.symbol] = id
            }
        }

        let resolvedInstruments = instruments
        return try await db.transaction { tx in
            guard try await claim(followId: followId, version: version.version, on: tx) else { return false }
            let trades = plan.orders.map { order in
                LedgerTrade(
                    symbol: order.symbol,
                    side: order.side,
                    quantity: order.quantity,
                    price: order.price,
                    tradeDate: now,
                    instrumentId: resolvedInstruments[order.symbol],
                    externalId: "pilot:\(followId.uuidString.lowercased()):v\(version.version):\(order.symbol)",
                    stockId: nil
                )
            }
            _ = try await recorder.record(trades, userId: follow.userId, portfolioId: listId, sourceProvider: "pilot", account: { try await PilotAccountResolver.findOrCreate(userId: $0, portfolioId: $1, on: $2) }, on: tx)
            for order in plan.orders {
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: order.side == .buy ? "buy" : "sell", symbol: order.symbol, quantity: order.quantity, price: order.price, pricedAt: now).create(on: tx)
            }
            for symbol in plan.unpriced {
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "skipped_unpriced", symbol: symbol, pricedAt: now, note: "No price available; left unchanged.").create(on: tx)
            }
            return true
        }
    }

    // MARK: - Watchlist

    private func applyWatchlist(follow: PilotFollow, pilot: Pilot, version: PilotBookVersion, previous: PilotBookVersion?, now: Date, on db: any Database) async throws -> Bool {
        guard let listId = follow.watchlistListId else { return false }
        let followId = try follow.requireID()
        let before = Set(previous?.weights.keys.map(\.self) ?? [])
        let added = version.weights.filter { !before.contains($0.key) }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let exited = before.subtracting(version.weights.keys).sorted()

        return try await db.transaction { tx in
            guard try await claim(followId: followId, version: version.version, on: tx) else { return false }
            for symbol in added {
                let note = try await activityNote(pilot: pilot, symbol: symbol, bought: true, on: tx)
                if let existing = try await WatchlistItem.query(on: tx).filter(\.$watchlistListId == listId).filter(\.$symbol == symbol).first() {
                    existing.status = WatchlistStatus.active.rawValue
                    existing.note = Self.appending(note, to: existing.note)
                    try await existing.save(on: tx)
                } else {
                    let count = try await WatchlistItem.query(on: tx).filter(\.$userId == follow.userId).count()
                    do {
                        try await watchlistLimit(follow.userId, count, tx)
                    } catch is BillingUpgradeRequiredError {
                        try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "skipped_limit", symbol: symbol, pricedAt: now, note: "Watchlist item limit reached.").create(on: tx)
                        continue
                    }
                    try await WatchlistItem(userId: follow.userId, watchlistListId: listId, symbol: symbol, note: note, status: .active).create(on: tx)
                }
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "watch_added", symbol: symbol, pricedAt: now, note: note).create(on: tx)
            }
            for symbol in exited {
                guard let item = try await WatchlistItem.query(on: tx).filter(\.$watchlistListId == listId).filter(\.$symbol == symbol).first() else { continue }
                let note = try await activityNote(pilot: pilot, symbol: symbol, bought: false, on: tx)
                item.status = WatchlistStatus.exited.rawValue
                item.note = Self.appending(note, to: item.note)
                try await item.save(on: tx)
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "watch_exited", symbol: symbol, pricedAt: now, note: note).create(on: tx)
            }
            return true
        }
    }

    /// Pilot activity is appended, never written over what is already there.
    private static func appending(_ note: String, to existing: String?) -> String {
        guard let existing, !existing.isEmpty else { return note }
        return existing + " · " + note
    }

    /// "Nancy Pelosi bought 2026-09-14" or, for funds, "Berkshire Hathaway held in 2026Q2".
    private func activityNote(pilot: Pilot, symbol: String, bought: Bool, on db: any Database) async throws -> String {
        let latest = try await PilotDisclosureRecord.query(on: db)
            .filter(\.$pilotId == pilot.requireID())
            .filter(\.$symbol == symbol)
            .sort(\.$transactionDate, .descending)
            .sort(\.$period, .descending)
            .first()
        if pilot.pilotKind == .fund {
            let period = latest?.period ?? "the latest filing"
            return bought ? "\(pilot.displayName) held in \(period)" : "\(pilot.displayName) no longer held after \(period)"
        }
        let date = latest?.transactionDate ?? "recently"
        return "\(pilot.displayName) \(bought ? "bought" : "sold") \(date)"
    }

    /// Moves `applied_version` forward inside the caller's transaction. False
    /// when another run already applied this version or a later one; the
    /// caller then writes nothing. This is the idempotency guard between pods.
    private func claim(followId: UUID, version: Int, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { return false }
        let rows = try await sql.raw("""
        UPDATE pilot_follows SET applied_version = \(bind: version), updated_at = NOW()
        WHERE id = \(bind: followId) AND applied_version < \(bind: version)
        RETURNING id
        """).all()
        return !rows.isEmpty
    }
}
