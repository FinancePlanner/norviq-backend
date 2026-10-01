import Fluent
import Foundation

enum LedgerTradeSide: Sendable {
    case buy
    case sell
}

struct LedgerTrade: Sendable, Equatable {
    let symbol: String
    let side: LedgerTradeSide
    let quantity: Double
    let price: Double
    let tradeDate: Date
    /// Nil when the instrument could not be resolved. The share and cash
    /// changes still happen; only the Transaction row is skipped, as in the
    /// manual sell path.
    let instrumentId: UUID?
    let externalId: String
    /// Sell from this exact row. Nil: the single row for `symbol` in the portfolio.
    let stockId: UUID?
}

struct LedgerTradeResult: Sendable, Equatable {
    let symbol: String
    let remainingShares: Double
}

enum LedgerTradeRecorderError: Error, Equatable {
    case holdingNotFound(String)
    case insufficientShares(String)
    case insufficientCash(String)
}

/// The one place a trade changes a portfolio. It keeps `stocks`, the
/// manual account's `cash_balances` and `transactions` in step.
///
/// Holdings live in two stores that nothing else links, so a buy that touched
/// only one of them would show up in either the summary or the P&L, not both.
/// The caller owns the database transaction: any throw here rolls back every
/// trade in the batch.
struct LedgerTradeRecorder: Sendable {
    private static let epsilon = 1e-9
    private static let cashTolerance = 0.005

    func record(
        _ trades: [LedgerTrade],
        userId: UUID,
        portfolioId: UUID,
        sourceProvider: String?,
        on db: any Database
    ) async throws -> [LedgerTradeResult] {
        let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: portfolioId, on: db)
        let accountId = try account.requireID()
        let cash = try await cashRow(accountId: accountId, currency: account.baseCurrency, on: db)

        var results: [LedgerTradeResult] = []
        for trade in trades {
            let remaining: Double
            switch trade.side {
            case .sell:
                remaining = try await applySell(trade, userId: userId, portfolioId: portfolioId, on: db)
                cash.balance += trade.quantity * trade.price
            case .buy:
                let cost = trade.quantity * trade.price
                guard cash.balance + Self.cashTolerance >= cost else {
                    throw LedgerTradeRecorderError.insufficientCash(trade.symbol)
                }
                remaining = try await applyBuy(trade, userId: userId, portfolioId: portfolioId, sourceProvider: sourceProvider, on: db)
                cash.balance -= cost
            }
            if let instrumentId = trade.instrumentId {
                try await Transaction(
                    accountId: accountId,
                    instrumentId: instrumentId,
                    externalId: trade.externalId,
                    type: trade.side == .buy ? TransactionType.buy.rawValue : TransactionType.sell.rawValue,
                    quantity: trade.quantity,
                    price: trade.price,
                    currency: account.baseCurrency,
                    tradeDate: trade.tradeDate
                ).save(on: db)
            }
            results.append(LedgerTradeResult(symbol: trade.symbol, remainingShares: remaining))
        }
        cash.asOf = Date()
        try await cash.save(on: db)
        return results
    }

    private func cashRow(accountId: UUID, currency: String, on db: any Database) async throws -> CashBalance {
        if let existing = try await CashBalance.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$currency == currency)
            .first()
        {
            return existing
        }
        return CashBalance(accountId: accountId, currency: currency, balance: 0, asOf: Date())
    }

    private func applySell(_ trade: LedgerTrade, userId: UUID, portfolioId: UUID, on db: any Database) async throws -> Double {
        var query = Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == portfolioId)
        if let stockId = trade.stockId {
            query = query.filter(\.$id == stockId)
        } else {
            query = query.filter(\.$symbol == trade.symbol)
        }
        guard let stock = try await query.first() else {
            throw LedgerTradeRecorderError.holdingNotFound(trade.symbol)
        }
        guard trade.quantity <= stock.shares + Self.epsilon else {
            throw LedgerTradeRecorderError.insufficientShares(trade.symbol)
        }
        if stock.shares - trade.quantity <= Self.epsilon {
            try await stock.delete(on: db)
            return 0
        }
        stock.shares -= trade.quantity
        try await stock.save(on: db)
        return stock.shares
    }

    /// Merges into an existing row the way `DatabaseStocksRepository.create`
    /// does: shares add, cost basis becomes the weighted average, and the
    /// earliest buy date is kept.
    private func applyBuy(_ trade: LedgerTrade, userId: UUID, portfolioId: UUID, sourceProvider: String?, on db: any Database) async throws -> Double {
        if let existing = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == portfolioId)
            .filter(\.$symbol == trade.symbol)
            .first()
        {
            let total = existing.shares + trade.quantity
            existing.buyPrice = (existing.shares * existing.buyPrice + trade.quantity * trade.price) / total
            existing.shares = total
            existing.buyDate = min(existing.buyDate, trade.tradeDate)
            try await existing.save(on: db)
            return total
        }
        try await Stock(
            userId: userId,
            portfolioListId: portfolioId,
            symbol: trade.symbol,
            shares: trade.quantity,
            buyPrice: trade.price,
            buyDate: trade.tradeDate,
            sourceProvider: sourceProvider
        ).create(on: db)
        return trade.quantity
    }
}
