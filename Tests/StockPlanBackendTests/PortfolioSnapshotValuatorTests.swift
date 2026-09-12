import Foundation
@testable import StockPlanBackend
import Testing

/// Tests for the valuation rule used to record portfolio history.
///
/// These exercise the pure rule directly — no database — because the rule is
/// where the correctness lives. Its defining property is strictness: an unpriced
/// position must be *reported*, never quietly valued at cost.
@Suite("PortfolioSnapshotValuator")
struct PortfolioSnapshotValuatorTests {
    private static let userId = UUID()
    private static let listId = UUID()

    private func makeStock(
        symbol: String,
        shares: Double,
        buyPrice: Double,
        buyDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Stock {
        Stock(
            userId: Self.userId,
            portfolioListId: Self.listId,
            symbol: symbol,
            shares: shares,
            buyPrice: buyPrice,
            buyDate: buyDate
        )
    }

    // MARK: - The strictness rule

    /// The defect this whole change exists to remove: an unpriced position
    /// valued at its buy price vanishes into the total, and a partially priced
    /// day becomes indistinguishable from a real move.
    @Test("An unpriced position is reported missing, never valued at cost")
    func unpricedPositionIsNotValuedAtCost() {
        let stocks = [
            makeStock(symbol: "AAPL", shares: 10, buyPrice: 150),
            makeStock(symbol: "NVDA", shares: 4, buyPrice: 500),
        ]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 200],
            cash: 0,
            currency: "USD"
        )

        // AAPL only: 10 × 200. NVDA contributes nothing — in particular it does
        // NOT contribute its 2000 cost basis.
        #expect(valuation.marketValue == 2000)
        #expect(valuation.pricedSymbols == 1)
        #expect(valuation.missingSymbols == 1)
        #expect(valuation.isFullyPriced == false)

        // Cost basis still counts every position, priced or not.
        #expect(valuation.costBasis == 3500)
    }

    @Test("A fully priced portfolio reports no missing symbols")
    func fullyPricedPortfolio() {
        let stocks = [
            makeStock(symbol: "AAPL", shares: 10, buyPrice: 150),
            makeStock(symbol: "MSFT", shares: 5, buyPrice: 300),
        ]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 200, "MSFT": 400],
            cash: 1000,
            currency: "USD"
        )

        #expect(valuation.marketValue == 4000)
        #expect(valuation.costBasis == 3000)
        #expect(valuation.cashBalance == 1000)
        #expect(valuation.totalValue == 5000)
        #expect(valuation.positionCount == 2)
        #expect(valuation.pricedSymbols == 2)
        #expect(valuation.missingSymbols == 0)
        #expect(valuation.isFullyPriced)
    }

    /// A zero or negative price is corrupt data, not a free portfolio.
    @Test("A non-positive price counts as missing, not as zero value")
    func nonPositivePriceIsMissing() {
        let stocks = [makeStock(symbol: "AAPL", shares: 10, buyPrice: 150)]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 0],
            cash: 0,
            currency: "USD"
        )

        #expect(valuation.marketValue == 0)
        #expect(valuation.missingSymbols == 1)
        #expect(valuation.isFullyPriced == false)
    }

    // MARK: - Market value versus cost basis

    /// The adjacent bug: `shares * buyPrice` reported as market value. These two
    /// must be able to disagree, and the snapshot records both.
    @Test("Market value and cost basis are tracked separately")
    func marketValueIsNotCostBasis() {
        let stocks = [makeStock(symbol: "AAPL", shares: 10, buyPrice: 150)]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 90],
            cash: 0,
            currency: "USD"
        )

        #expect(valuation.marketValue == 900)
        #expect(valuation.costBasis == 1500)
        #expect(valuation.marketValue != valuation.costBasis)
    }

    // MARK: - Symbol handling

    @Test("Symbols are matched case- and whitespace-insensitively")
    func symbolNormalization() {
        let stocks = [makeStock(symbol: "  aapl ", shares: 10, buyPrice: 150)]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 200],
            cash: 0,
            currency: "USD"
        )

        #expect(valuation.marketValue == 2000)
        #expect(valuation.missingSymbols == 0)
    }

    @Test("Two rows of the same symbol both count")
    func duplicateSymbolRows() {
        let stocks = [
            makeStock(symbol: "AAPL", shares: 10, buyPrice: 150),
            makeStock(symbol: "AAPL", shares: 5, buyPrice: 180),
        ]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 200],
            cash: 0,
            currency: "USD"
        )

        #expect(valuation.marketValue == 3000)
        #expect(valuation.costBasis == 2400)
        #expect(valuation.positionCount == 2)
    }

    @Test("uniqueSymbols normalizes and drops blanks and duplicates")
    func uniqueSymbolsHelper() {
        let symbols = PortfolioSnapshotValuator.uniqueSymbols(
            ["aapl", "AAPL", " msft ", "", "   "]
        )

        #expect(symbols == ["AAPL", "MSFT"])
    }

    // MARK: - Empty portfolios

    /// A dormant account must not accrue a row a day forever.
    @Test("An empty portfolio with no cash is recognised as empty")
    func emptyPortfolio() {
        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: [],
            prices: [:],
            cash: 0,
            currency: "USD"
        )

        #expect(valuation.isEmpty)
        #expect(valuation.totalValue == 0)
        // Vacuously fully priced: there was nothing to price.
        #expect(valuation.isFullyPriced)
    }

    @Test("A portfolio holding only cash is not empty")
    func cashOnlyPortfolio() {
        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: [],
            prices: [:],
            cash: 2500,
            currency: "USD"
        )

        #expect(valuation.isEmpty == false)
        #expect(valuation.totalValue == 2500)
    }

    // MARK: - Rounding

    @Test("Money is rounded to cents")
    func roundsToCents() {
        let stocks = [makeStock(symbol: "AAPL", shares: 3, buyPrice: 10.111)]

        let valuation = PortfolioSnapshotValuator.valuate(
            stocks: stocks,
            prices: ["AAPL": 33.333],
            cash: 0.005,
            currency: "USD"
        )

        #expect(valuation.marketValue == 100.0)
        #expect(valuation.costBasis == 30.33)
        #expect(valuation.cashBalance == 0.01)
    }

    // MARK: - Day boundaries

    @Test("startOfDay is UTC, so a day is the same day everywhere")
    func startOfDayIsUTC() {
        // 2024-03-15T23:30:00Z — late in the UTC day, already tomorrow in Tokyo.
        let date = Date(timeIntervalSince1970: 1_710_545_400)
        let day = PortfolioSnapshotValuator.startOfDay(date)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: day)

        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 0)
    }

    @Test("addDays crosses month boundaries")
    func addDaysCrossesMonths() {
        // 2024-03-01T00:00:00Z
        let march1 = Date(timeIntervalSince1970: 1_709_251_200)
        let back = PortfolioSnapshotValuator.addDays(march1, days: -1)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.month, .day], from: back)

        // 2024 is a leap year.
        #expect(components.month == 2)
        #expect(components.day == 29)
    }
}
