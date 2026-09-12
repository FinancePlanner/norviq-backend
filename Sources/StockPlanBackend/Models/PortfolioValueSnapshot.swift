import Fluent
import Foundation
import Vapor

/// One day's observed value of one portfolio list.
///
/// Snapshots are append-only truth: whatever is not captured on the day it
/// happened is unrecoverable, which is why the money columns are stored
/// separately rather than pre-summed into a single total.
///
/// `capturedOn` is a calendar date, not a timestamp. The unique constraint on
/// (user, list, day) is the entire idempotency mechanism for the capture job —
/// it can tick hourly, crash, redeploy or double-run and still produce one row
/// per day.
final class PortfolioValueSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_value_snapshots"

    /// How the row's value was arrived at.
    enum Source: String {
        /// Observed on the day it is dated.
        case live
        /// Reconstructed afterwards from historical prices. Approximate: `Stock`
        /// rows are mutable and carry no sell log, and cash is held flat.
        case backfill
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "portfolio_list_id")
    var portfolioListId: UUID

    @Field(key: "captured_on")
    var capturedOn: Date

    @Field(key: "currency")
    var currency: String

    /// Σ shares × price. Holdings only — cash is `cashBalance`.
    @Field(key: "market_value")
    var marketValue: Double

    /// Σ shares × buy price. Stored alongside market value so unrealized P&L is
    /// historical for free, and so a row that fell back to cost is detectable.
    @Field(key: "cost_basis")
    var costBasis: Double

    @Field(key: "cash_balance")
    var cashBalance: Double

    @Field(key: "position_count")
    var positionCount: Int

    @Field(key: "source")
    var source: String

    /// Symbols that resolved a price. With `missingSymbols`, decides whether the
    /// row is trustworthy — without them a partially-priced day is
    /// indistinguishable from a real drop.
    @Field(key: "priced_symbols")
    var pricedSymbols: Int

    @Field(key: "missing_symbols")
    var missingSymbols: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        portfolioListId: UUID,
        capturedOn: Date,
        currency: String,
        marketValue: Double,
        costBasis: Double,
        cashBalance: Double,
        positionCount: Int,
        source: Source,
        pricedSymbols: Int,
        missingSymbols: Int
    ) {
        self.id = id
        self.userId = userId
        self.portfolioListId = portfolioListId
        self.capturedOn = capturedOn
        self.currency = currency
        self.marketValue = marketValue
        self.costBasis = costBasis
        self.cashBalance = cashBalance
        self.positionCount = positionCount
        self.source = source.rawValue
        self.pricedSymbols = pricedSymbols
        self.missingSymbols = missingSymbols
    }

    /// What the chart plots: holdings plus cash.
    var totalValue: Double {
        marketValue + cashBalance
    }
}
